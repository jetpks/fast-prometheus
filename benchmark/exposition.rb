# frozen_string_literal: true

# Exposition benchmark suite: what a scrape costs, in four views.
#
#   1. Scrape, end to end: Middleware::Exporter served by Async::HTTP on a
#      loopback socket and scraped by Async::HTTP::Client, in every
#      content variant Prometheus negotiates (text/protobuf, gzip or not).
#   2. Where a scrape goes: each stage of one scrape on its own (collect,
#      render, gzip) and the whole Exposition.render, with the Ruby objects
#      and malloc bytes each stage allocates.
#   3. By registry size: the text and protobuf renderers and
#      prometheus-client's text formatter over 1k to 100k series.
#   4. Against google-protobuf: the two google-protobuf encoders this gem
#      shipped before fast-protowire (whole family, one Metric at a time),
#      with live native arenas and GC time.
#
#   bundle exec ruby benchmark/exposition.rb            # 36,000 series x 12 labels, ~3 minutes
#   BENCH_QUICK=1 bundle exec ruby benchmark/exposition.rb
#
# Allocation columns are one call with GC disabled, so they are the call's
# whole footprint: Ruby objects (GC.stat) and bytes malloc'd for their
# payloads and, for google-protobuf, its native arenas. Timed columns are
# the mean over the timed calls with GC enabled.

require "objspace"
require "zlib"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "prometheus/client"
require "prometheus/client/formats/text"
require_relative "../lib/fast/prometheus"
require_relative "../lib/fast/prometheus/formats/text"
require_relative "../lib/fast/prometheus/formats/protobuf"
require_relative "../lib/fast/prometheus/exposition"
require_relative "../lib/fast/prometheus/middleware/exporter"

$LOAD_PATH.unshift(File.expand_path("../fixtures", __dir__))
require "reference"

QUICK = ENV["BENCH_QUICK"]
LABELS = 12
LABEL_NAMES = Array.new(LABELS) { |i| :"label_#{i}" }
MAIN = Integer(ENV.fetch("SERIES", QUICK ? 5_000 : 36_000))
SIZES = QUICK ? [1_000, MAIN] : [1_000, 10_000, MAIN, 100_000]
RUNS = QUICK ? 3 : 10
PROTOBUF_ACCEPT = "application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited"
TEXT_ACCEPT = "text/plain;version=0.0.4"

# A registry shaped like production: one wide counter carrying the series
# count, plus a labeled histogram, gauge and summary. Built for both
# libraries from the same label sets.
module Registries
  def self.label_set(index)
    LABEL_NAMES.to_h { |name| [name, "#{name}-#{index}".ljust(12, "x")] }
  end

  def self.build(series)
    [fill(Fast::Prometheus::Registry.new, series), fill(Prometheus::Client::Registry.new, series)]
  end

  def self.fill(registry, series)
    wide = registry.counter(:wide_events_total, docstring: "wide labeled counter", labels: LABEL_NAMES)
    series.times { |i| wide.increment(labels: label_set(i)) }
    histogram = registry.histogram(:request_seconds, docstring: "request latency", labels: [:path])
    gauge = registry.gauge(:temperature, docstring: "gauge", labels: [:room])
    summary = registry.summary(:payload_bytes, docstring: "summary", labels: [:kind])
    20.times do |n|
      histogram.observe(n * 0.01, labels: { path: "/p#{n}" })
      gauge.set(n, labels: { room: "r#{n}" })
      summary.observe(n, labels: { kind: "k#{n}" })
    end
    registry
  end
end

module Measure
  # One call with GC off: everything it allocated is still there to count.
  def self.footprint
    GC.start
    GC.disable
    objects = GC.stat(:total_allocated_objects)
    malloc = GC.stat(:malloc_increase_bytes)
    result = yield
    stats = { objects: GC.stat(:total_allocated_objects) - objects,
              malloc_mib: (GC.stat(:malloc_increase_bytes) - malloc) / 1024.0 / 1024,
              arenas: ObjectSpace.each_object(Google::Protobuf::Internal::Arena).count,
              bytes: result.respond_to?(:bytesize) ? result.bytesize : 0 }
    GC.enable
    GC.start
    stats
  end

  # Timed calls with GC on: what the process pays per call.
  def self.timed(count, &block)
    block.call
    GC.start
    minor = GC.stat(:minor_gc_count)
    major = GC.stat(:major_gc_count)
    gc_ms = GC.stat(:time)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count.times { block.call }
    seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / count
    { seconds: seconds, minor: GC.stat(:minor_gc_count) - minor, major: GC.stat(:major_gc_count) - major,
      gc_ms: GC.stat(:time) - gc_ms }
  end
end

module Table
  def self.print(title, columns, rows)
    puts "### #{title}"
    puts
    puts "| #{columns.join(' | ')} |"
    puts "|#{'---|' * columns.size}"
    rows.each { |cells| puts "| #{cells.join(' | ')} |" }
    puts
  end

  def self.commas(integer)
    integer.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  end

  def self.megabytes(bytes)
    "#{(bytes / 1e6).round(1)} MB"
  end
end

# The google-protobuf encoders fast-prometheus used before fast-protowire,
# over the same snapshot and the protoc-generated classes under fixtures/pb.
module GoogleProtobuf
  PB = Io::Prometheus::Client
  TYPES = { counter: :COUNTER, gauge: :GAUGE, summary: :SUMMARY, histogram: :HISTOGRAM }.freeze
  METRIC_TAG = Fast::Protowire::Wire.tag(4, Fast::Protowire::Wire::LENGTH_DELIMITED)

  # 0.2.0: every series as a message inside one MetricFamily, encoded once.
  def self.whole_family(snapshot)
    snapshot.metrics.each_with_object(String.new) do |ms, out|
      metrics = ms.series.map { |values, value| metric(ms.label_names, values, value, ms.type) }
      family = PB::MetricFamily.new(name: ms.name.to_s, help: ms.docstring, type: TYPES.fetch(ms.type), metric: metrics)
      frame = PB::MetricFamily.encode(family)
      Fast::Protowire::Wire.append_varint(out, frame.bytesize)
      out << frame
    end
  end

  # The streamed fix: header, then one Metric encoded and appended at a time.
  def self.per_series(snapshot)
    snapshot.metrics.each_with_object(String.new) do |ms, out|
      header = PB::MetricFamily.new(name: ms.name.to_s, help: ms.docstring, type: TYPES.fetch(ms.type))
      frame = ms.series.each_with_object(PB::MetricFamily.encode(header)) do |(values, value), buffer|
        encoded = PB::Metric.encode(metric(ms.label_names, values, value, ms.type))
        Fast::Protowire::Wire.append_length_delimited(buffer, METRIC_TAG, encoded)
      end
      Fast::Protowire::Wire.append_varint(out, frame.bytesize)
      out << frame
    end
  end

  def self.metric(names, values, value, type)
    labels = names.zip(values).map { |name, label_value| PB::LabelPair.new(name: name.to_s, value: label_value) }
    case type
    when :counter then PB::Metric.new(label: labels, counter: PB::Counter.new(value: value))
    when :gauge then PB::Metric.new(label: labels, gauge: PB::Gauge.new(value: value))
    when :summary
      PB::Metric.new(label: labels, summary: PB::Summary.new(sample_count: value.count, sample_sum: value.sum))
    when :histogram
      buckets = value.cumulative_buckets.map { |bound, count| PB::Bucket.new(upper_bound: bound, cumulative_count: count) }
      PB::Metric.new(label: labels,
                     histogram: PB::Histogram.new(sample_count: value.count, sample_sum: value.sum, bucket: buckets))
    end
  end
end

# Middleware::Exporter on a loopback Async::HTTP server, scraped over one
# keep-alive HTTP/1.1 connection as Prometheus does. Returns [s/scrape,
# bytes on the wire].
def scrape(registry, accept:, gzip:)
  app = Fast::Prometheus::Middleware::Exporter.new(Protocol::HTTP::Middleware::NotFound, registry: registry)
  endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:0", protocol: Async::HTTP::Protocol::HTTP1)
  headers = { "accept" => accept }
  headers["accept-encoding"] = "gzip" if gzip
  result = nil
  Async do |task|
    bound = endpoint.bound
    server = task.async { Async::HTTP::Server.new(app, bound, protocol: endpoint.protocol, scheme: endpoint.scheme).run }
    port = bound.sockets.first.local_address.ip_port
    client = Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}"))
    get = lambda do
      response = client.get("/metrics", headers)
      raise "HTTP #{response.status}" unless response.status == 200

      response.read
    end
    bytes = get.call.bytesize
    result = [Measure.timed(RUNS, &get)[:seconds], bytes]
  ensure
    client&.close
    server&.stop
    bound&.close
  end
  result
end

versions = %w[async-http google-protobuf prometheus-client].map { |gem| "#{gem} #{Gem.loaded_specs[gem].version}" }
puts "#{RUBY_DESCRIPTION}; #{versions.join('; ')}"
puts "#{MAIN} series x #{LABELS} labels (+60 small series), #{RUNS} timed calls each"
puts

fast, client = Registries.build(MAIN)
snapshot = fast.collect

# -- 1. Scrape, end to end ---------------------------------------------------

rows = [["text", TEXT_ACCEPT, false], ["text, gzip", TEXT_ACCEPT, true],
        ["protobuf", PROTOBUF_ACCEPT, false], ["protobuf, gzip", PROTOBUF_ACCEPT, true]].map do |name, accept, gzip|
  seconds, bytes = scrape(fast, accept: accept, gzip: gzip)
  [name, Table.megabytes(bytes), seconds.round(3)]
end
Table.print("Scrape, end to end (Middleware::Exporter over Async::HTTP, #{MAIN} series)",
            ["content", "on the wire", "s/scrape"], rows)

# -- 2. Where a scrape goes ----------------------------------------------------

text = Fast::Prometheus::Formats::Text.render(snapshot)
protobuf = Fast::Prometheus::Formats::Protobuf.render(snapshot)
stages = {
  "Registry#collect" => -> { fast.collect },
  "Formats::Text.render" => -> { Fast::Prometheus::Formats::Text.render(snapshot) },
  "Formats::Protobuf.render" => -> { Fast::Prometheus::Formats::Protobuf.render(snapshot) },
  "Zlib.gzip (text)" => -> { Zlib.gzip(text) },
  "Zlib.gzip (protobuf)" => -> { Zlib.gzip(protobuf) },
  "Exposition.render, text + gzip" => lambda {
    Fast::Prometheus::Exposition.render(fast, accept: TEXT_ACCEPT, accept_encoding: "gzip").first
  },
  "Exposition.render, protobuf + gzip" => lambda {
    Fast::Prometheus::Exposition.render(fast, accept: PROTOBUF_ACCEPT, accept_encoding: "gzip").first
  }
}
rows = stages.map do |name, call|
  f = Measure.footprint(&call)
  t = Measure.timed(RUNS, &call)
  [name, Table.megabytes(f[:bytes]), t[:seconds].round(3), Table.commas(f[:objects]), f[:malloc_mib].round(1)]
end
Table.print("Where a scrape goes (#{MAIN} series)",
            ["stage", "output", "s/call", "objects/call", "malloc MiB/call"], rows)

# -- 3. By registry size ------------------------------------------------------

rows = SIZES.map do |size|
  sized_fast, sized_client = size == MAIN ? [fast, client] : Registries.build(size)
  sized_snapshot = sized_fast.collect
  renderers = [-> { Fast::Prometheus::Formats::Text.render(sized_snapshot) },
               -> { Fast::Prometheus::Formats::Protobuf.render(sized_snapshot) },
               -> { Prometheus::Client::Formats::Text.marshal(sized_client) }]
  cells = renderers.flat_map do |call|
    [Measure.timed(RUNS, &call)[:seconds].round(3), Table.commas(Measure.footprint(&call)[:objects])]
  end
  [Table.commas(size), *cells]
end
Table.print("By registry size (series x #{LABELS} labels)",
            ["series", "fast text s", "objects", "fast protobuf s", "objects", "prometheus-client text s", "objects"],
            rows)

# -- 4. Against google-protobuf -----------------------------------------------

renderers = {
  "fast-prometheus protobuf (fast-protowire)" => -> { Fast::Prometheus::Formats::Protobuf.render(snapshot) },
  "google-protobuf, one Metric at a time" => -> { GoogleProtobuf.per_series(snapshot) },
  "google-protobuf, whole family (0.2.0)" => -> { GoogleProtobuf.whole_family(snapshot) }
}
rows = renderers.map do |name, call|
  f = Measure.footprint(&call)
  t = Measure.timed(RUNS, &call)
  [name, t[:seconds].round(3), Table.commas(f[:objects]), f[:malloc_mib].round(1), Table.commas(f[:arenas]),
   "#{t[:minor]} minor + #{t[:major]} major", t[:gc_ms]]
end
Table.print("Against google-protobuf (#{MAIN} series, same bytes)",
            ["encoder", "s/render", "objects/render", "malloc MiB/render", "live arenas after",
             "GC runs (#{RUNS} renders)", "GC ms"], rows)
