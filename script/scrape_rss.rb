#!/usr/bin/env ruby
# frozen_string_literal: true

# Memory harness: render a large labeled registry many times and report
# process RSS + post-GC protobuf arena population per sample, so a leak on
# the exposition path shows up as a slope rather than an anecdote.
#
# Modes:
#   server  fork a child serving Middleware::Exporter over Async::HTTP::Server
#           (the Falcon-native path); scrape it over one keep-alive connection
#           and sample the child's RSS
#   fiber   render in-process inside an Async reactor, no HTTP
#   inline  render in-process on the main fiber, no reactor — the control
#
# Usage:
#   bundle exec ruby script/scrape_rss.rb [--mode server|fiber|inline]
#     [--format protobuf|text] [--gzip] [--scrapes N] [--every N]
#     [--series N] [--labels N] [--value-bytes N] [--mint N] [--gc-each-sample]
#     [--ballast N] [--threaded] [--clients N]
#
# --mint N increments N never-seen label combinations between scrapes, the
# way a production registry keeps minting series. Samples are taken without a
# forced GC unless --gc-each-sample, so the run sees what the process sees;
# the final row is always taken after a full GC to show what is reclaimable.
# --ballast N retains N small objects in the rendering process before the
# run starts, so GC cadence (major GC in particular) resembles a large app
# heap rather than a bare script. --threaded runs the server's reactor on a
# non-main OS thread, as a Falcon --threaded worker does; --clients N scrapes
# from N concurrent keep-alive connections, as an HA Prometheus pair does.

require "optparse"
require "json"
require "objspace"

require "async"
require "async/http/endpoint"
require "async/http/client"
require "async/http/server"

require "fast/prometheus"
require "fast/prometheus/exposition"
require "fast/prometheus/middleware/exporter"

module ScrapeRSS
  Options = Struct.new(:mode, :format, :gzip, :scrapes, :every, :series, :labels, :value_bytes, :mint, :gc_each_sample,
                       :ballast, :threaded, :clients, keyword_init: true) do
    def self.parse(argv)
      options = new(mode: "server", format: "protobuf", gzip: false, scrapes: 200, every: 20, series: 650, labels: 12,
                    value_bytes: 12, mint: 0, gc_each_sample: false, ballast: 0, threaded: false, clients: 1)
      OptionParser.new do |o|
        o.on("--mode MODE", %w[server fiber inline]) { |v| options.mode = v }
        o.on("--format FORMAT", %w[protobuf text]) { |v| options.format = v }
        o.on("--gzip") { options.gzip = true }
        o.on("--scrapes N", Integer) { |v| options.scrapes = v }
        o.on("--every N", Integer) { |v| options.every = v }
        o.on("--series N", Integer) { |v| options.series = v }
        o.on("--labels N", Integer) { |v| options.labels = v }
        o.on("--value-bytes N", Integer) { |v| options.value_bytes = v }
        o.on("--mint N", Integer) { |v| options.mint = v }
        o.on("--gc-each-sample") { options.gc_each_sample = true }
        o.on("--ballast N", Integer) { |v| options.ballast = v }
        o.on("--threaded") { options.threaded = true }
        o.on("--clients N", Integer) { |v| options.clients = v }
      end.parse!(argv)
      options
    end

    def accept
      format == "protobuf" ? Fast::Prometheus::Exposition::PROTOBUF_ACCEPT : "text/plain"
    end

    def accept_encoding
      gzip ? "gzip" : nil
    end
  end

  # A registry shaped like a production one that has minted many series on a
  # wide label set: one wide counter carrying most of the mass, plus a few
  # ordinary metrics so every family type is on the render path.
  class Fixture
    attr_reader :registry

    def initialize(series:, labels:, value_bytes:)
      @registry = Fast::Prometheus::Registry.new
      @label_names = Array.new(labels) { |i| :"label_#{i}" }
      @value_bytes = value_bytes
      @minted = 0

      @wide = @registry.counter(:wide_events_count, docstring: "wide labeled counter", labels: @label_names)
      mint(series)
      seed_small_metrics
    end

    # Increment +count+ never-before-seen label combinations on the wide counter.
    def mint(count)
      count.times do
        @minted += 1
        @wide.increment(labels: @label_names.to_h { |name| [name, "#{name}-#{@minted}".ljust(@value_bytes, "x")] })
      end
    end

    private

    def seed_small_metrics
      registry = @registry

      histogram = registry.histogram(:request_seconds, docstring: "request latency", labels: [:path])
      native = registry.native_histogram(:native_seconds, docstring: "native latency", labels: [:path])
      gauge = registry.gauge(:temperature, docstring: "gauge", labels: [:room])
      summary = registry.summary(:payload_bytes, docstring: "summary", labels: [:kind])
      20.times do |n|
        histogram.observe(n * 0.01, labels: { path: "/p#{n}" })
        native.observe(n * 0.01, labels: { path: "/p#{n}" })
        gauge.set(n, labels: { room: "r#{n}" })
        summary.observe(n, labels: { kind: "k#{n}" })
      end
    end
  end

  # Long-lived heap filler for the rendering process; held in a constant so
  # it stays reachable for the whole run.
  module Ballast
    @held = []

    def self.retain(count)
      count.times { |i| @held << "ballast-#{i}" }
      GC.start
    end
  end

  # One measurement of the process under test, taken after a full GC so the
  # arena population reflects retention rather than pending garbage.
  module Sample
    ARENA = Google::Protobuf::Internal::Arena

    def self.take(pid = Process.pid, collect: false)
      GC.start if collect
      {
        rss_mib: rss_mib(pid),
        live_slots: GC.stat(:heap_live_slots),
        arenas: ObjectSpace.each_object(ARENA).count,
        arena_mib: ObjectSpace.memsize_of_all(ARENA) / 1024.0 / 1024.0
      }
    end

    def self.rss_mib(pid)
      Integer(`ps -o rss= -p #{pid}`) / 1024.0
    end
  end

  # Prints the sample table and, at the end, the RSS slope over the second
  # half of the run — the first half absorbs warm-up growth.
  class Report
    COLUMNS = "%<scrape>8s %<rss_mib>10s %<d_rss>10s %<live_slots>12s %<arenas>8s %<arena_mib>10s  %<note>s"
    ROW = "%<scrape>8d %<rss_mib>10.1f %<d_rss>+10.1f %<live_slots>12d %<arenas>8d %<arena_mib>10.1f  %<note>s"

    def initialize(options)
      @options = options
      @rows = []
      puts "mode=#{options.mode} format=#{options.format} gzip=#{options.gzip} " \
           "series=#{options.series} labels=#{options.labels} scrapes=#{options.scrapes}"
      puts format(COLUMNS, scrape: "scrape", rss_mib: "rss_mib", d_rss: "d_rss", live_slots: "live_slots",
                           arenas: "arenas", arena_mib: "arena_mib", note: "note")
    end

    def add(scrape, sample, note = "")
      delta = @rows.empty? ? 0.0 : sample[:rss_mib] - @rows.last[1][:rss_mib]
      @rows << [scrape, sample] if note.empty?
      puts format(ROW, sample.merge(scrape: scrape, d_rss: delta, note: note))
    end

    def finish(final_sample)
      add(@rows.last[0], final_sample, "after GC.start")
      half = @rows[(@rows.size / 2)..]
      first = half.first
      last = half.last
      scrapes = last[0] - first[0]
      growth = last[1][:rss_mib] - first[1][:rss_mib]
      slope = scrapes.zero? ? 0.0 : growth / scrapes
      puts format("RSS slope over last %<scrapes>d scrapes: %<slope>+.3f MiB/scrape (%<growth>+.1f MiB total); " \
                  "arenas %<first>d -> %<last>d",
                  scrapes: scrapes, slope: slope, growth: growth, first: first[1][:arenas], last: last[1][:arenas])
    end
  end

  # Drives the render loop in-process; +yielder+ runs each render.
  class InProcess
    def initialize(options, fixture)
      @options = options
      @fixture = fixture
    end

    def run
      Ballast.retain(@options.ballast)
      report = Report.new(@options)
      report.add(0, sample)
      1.upto(@options.scrapes) do |n|
        @fixture.mint(@options.mint)
        Fast::Prometheus::Exposition.render(@fixture.registry, accept: @options.accept,
                                                               accept_encoding: @options.accept_encoding)
        report.add(n, sample) if (n % @options.every).zero?
      end
      report.finish(Sample.take(collect: true))
    end

    private

    def sample
      Sample.take(collect: @options.gc_each_sample)
    end
  end

  # Forks a child serving /metrics (and /sample, which returns the child's
  # own Sample as JSON), then scrapes it over one keep-alive HTTP/1.1
  # connection, exactly as Prometheus does.
  class Server
    HOST = "127.0.0.1"

    def initialize(options, fixture)
      @options = options
      @fixture = fixture
    end

    def run
      reader, writer = IO.pipe
      pid = fork { serve(writer) }
      writer.close
      port = Integer(reader.gets)
      scrape_loop(pid, port)
    ensure
      Process.kill("TERM", pid) if pid
      Process.wait(pid) if pid
    end

    private

    def serve(ready)
      Ballast.retain(@options.ballast)
      app = Fast::Prometheus::Middleware::Exporter.new(Control.new(Protocol::HTTP::Middleware::NotFound, @fixture),
                                                       registry: @fixture.registry)
      endpoint = Async::HTTP::Endpoint.parse("http://#{HOST}:0", protocol: Async::HTTP::Protocol::HTTP1)
      reactor = lambda do
        Async do
          bound = endpoint.bound
          Async::HTTP::Server.new(app, bound, protocol: endpoint.protocol, scheme: endpoint.scheme).run
          ready.puts(bound.sockets.first.local_address.ip_port)
          ready.close
        end
      end
      @options.threaded ? Thread.new(&reactor).join : reactor.call
    end

    def scrape_loop(pid, port)
      report = Report.new(@options)
      Async do |task|
        client = Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("http://#{HOST}:#{port}"))
        report.add(0, sample(client, pid))
        1.upto(@options.scrapes) do |number|
          client.get("/mint?#{@options.mint}").finish if @options.mint.positive?
          @options.clients.times.map { task.async { scrape(client, number) } }.each(&:wait)
          report.add(number, sample(client, pid)) if (number % @options.every).zero?
        end
        report.finish(sample(client, pid, collect: true))
      ensure
        client&.close
      end
    end

    # One scrape; concurrent calls each get their own pooled connection.
    def scrape(client, number)
      headers = { "accept" => @options.accept }
      headers["accept-encoding"] = @options.accept_encoding if @options.accept_encoding
      response = client.get("/metrics", headers)
      raise "scrape #{number}: HTTP #{response.status}" unless response.status == 200

      response.read
    end

    def sample(client, pid, collect: @options.gc_each_sample)
      response = client.get("/sample?#{collect ? 'gc' : ''}")
      JSON.parse(response.read, symbolize_names: true).merge(rss_mib: Sample.rss_mib(pid))
    end
  end

  # Child-side control surface: /sample returns the child's own measurement
  # (after a full GC when the query is "gc"); /mint?N mints N new series.
  class Control < Protocol::HTTP::Middleware
    def initialize(delegate, fixture)
      super(delegate)
      @fixture = fixture
    end

    def call(request)
      path, query = request.path.split("?", 2)
      case path
      when "/sample"
        json(Sample.take(collect: query == "gc"))
      when "/mint"
        @fixture.mint(Integer(query))
        json({})
      else
        super
      end
    end

    private

    def json(payload)
      Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [JSON.generate(payload)]]
    end
  end

  DRIVERS = { "server" => Server, "fiber" => InProcess, "inline" => InProcess }.freeze

  def self.main(argv)
    options = Options.parse(argv)
    fixture = Fixture.new(series: options.series, labels: options.labels, value_bytes: options.value_bytes)
    driver = DRIVERS.fetch(options.mode).new(options, fixture)
    if options.mode == "fiber"
      Async { driver.run }
    else
      driver.run
    end
  end
end

ScrapeRSS.main(ARGV)
