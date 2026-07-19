# frozen_string_literal: true

# E2E: serve metrics via the installed gem's Exporter middleware, scrape with
# real Prometheus, verify PromQL sees the counter and native histogram.
# Adapted from script/e2e_prometheus_scrape.rb to run against the installed
# gem rather than the checkout's lib/.

require "tmpdir"
require "json"
require "net/http"
require "timeout"

PROMETHEUS_BIN = ENV.fetch("PROMETHEUS_BIN")
METRICS_HOST = "127.0.0.1"
METRICS_PORT = 19_404
PROMETHEUS_PORT = 19_405
SCRAPE_INTERVAL = 1
POLL_INTERVAL = 1
DEADLINE = 90

unless File.executable?(PROMETHEUS_BIN)
  puts "CHECK e2e-scrape: SKIP prometheus binary not found at #{PROMETHEUS_BIN}"
  exit
end

require "async"
require "async/http/endpoint"
require "async/http/server"

require "fast/prometheus"
require "fast/prometheus/middleware/exporter"

begin
  Dir.mktmpdir do |tmpdir|
    config_path = File.join(tmpdir, "prometheus.yml")
    storage_path = File.join(tmpdir, "data")

    File.write(config_path, <<~YAML)
      global:
        scrape_interval: #{SCRAPE_INTERVAL}s

      scrape_configs:
        - job_name: "fast_prometheus_integration"
          scrape_native_histograms: true
          static_configs:
            - targets: ["#{METRICS_HOST}:#{METRICS_PORT}"]
    YAML

    registry = Fast::Prometheus::Registry.new
    counter = registry.counter(:fpi_e2e_jobs_total, docstring: "E2E jobs total")
    counter.increment(by: 3)

    nh = registry.native_histogram(:fpi_e2e_duration_seconds, docstring: "E2E duration")
    nh.observe(0.05)
    nh.observe(0.2)
    nh.observe(1.5)

    middleware = Fast::Prometheus::Middleware::Exporter.new(
      Protocol::HTTP::Middleware::NotFound,
      registry: registry
    )

    endpoint = Async::HTTP::Endpoint.parse(
      "http://#{METRICS_HOST}:#{METRICS_PORT}",
      protocol: Async::HTTP::Protocol::HTTP1
    )

    prometheus_pid = nil
    outcome = nil

    begin
      Async do
        bound = endpoint.bound
        server = Async::HTTP::Server.new(middleware, bound, protocol: endpoint.protocol, scheme: endpoint.scheme)
        server_task = server.run

        prometheus_pid = spawn(
          PROMETHEUS_BIN,
          "--config.file=#{config_path}",
          "--storage.tsdb.path=#{storage_path}",
          "--web.listen-address=#{METRICS_HOST}:#{PROMETHEUS_PORT}",
          err: File::NULL,
          out: File::NULL
        )

        ready = false
        Timeout.timeout(15) do
          loop do
            begin
              uri = URI("http://#{METRICS_HOST}:#{PROMETHEUS_PORT}/-/ready")
              response = Net::HTTP.get_response(uri)
              if response.is_a?(Net::HTTPSuccess)
                ready = true
                break
              end
            rescue Errno::ECONNREFUSED
              nil
            end
            sleep POLL_INTERVAL
          end
        end

        raise "prometheus did not become ready in time" unless ready

        query_url = "http://#{METRICS_HOST}:#{PROMETHEUS_PORT}/api/v1/query"
        counter_ok = false
        histogram_ok = false

        Timeout.timeout(DEADLINE) do
          loop do
            counter_resp = Timeout.timeout(5) { Net::HTTP.get_response(URI("#{query_url}?query=fpi_e2e_jobs_total")) }
            if counter_resp.is_a?(Net::HTTPSuccess)
              data = JSON.parse(counter_resp.body)
              counter_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 3
            end

            histogram_resp = Timeout.timeout(5) do
              Net::HTTP.get_response(URI("#{query_url}?query=histogram_count(fpi_e2e_duration_seconds)"))
            end
            if histogram_resp.is_a?(Net::HTTPSuccess)
              data = JSON.parse(histogram_resp.body)
              histogram_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 3
            end

            break if counter_ok && histogram_ok

            sleep POLL_INTERVAL
          end
        end

        outcome = counter_ok && histogram_ok ? :pass : :fail

        server_task.stop
        bound.close
      end
    ensure
      if prometheus_pid
        begin
          Process.kill("TERM", prometheus_pid)
        rescue Errno::EPERM, Errno::ESRCH
          nil
        end
        begin
          Process.wait(prometheus_pid)
        rescue Errno::ECHILD
          nil
        end
      end
    end

    if outcome == :pass
      puts "CHECK e2e-scrape: PASS"
    else
      puts "CHECK e2e-scrape: FAIL scraped values never satisfied PromQL expectations"
    end
  end
rescue StandardError => e
  puts "CHECK e2e-scrape: FAIL #{e.class}: #{e.message}"
end
