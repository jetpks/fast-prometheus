# frozen_string_literal: true

# E2E: push metrics via OTLP HTTP from the installed gem to a real Prometheus
# instance, verify they land via PromQL. Adapted from script/e2e_otlp_http.rb
# to run against the installed gem rather than the checkout's lib/.

require "tmpdir"
require "json"
require "net/http"
require "timeout"

PROMETHEUS_BIN = ENV.fetch("PROMETHEUS_BIN")
PROMETHEUS_HOST = "127.0.0.1"
PROMETHEUS_PORT = 19_406
POLL_INTERVAL = 1
DEADLINE = 90

unless File.executable?(PROMETHEUS_BIN)
  puts "CHECK e2e-otlp-http: SKIP prometheus binary not found at #{PROMETHEUS_BIN}"
  exit
end

require "async"
require "async/http/endpoint"

require "fast/prometheus"
require "fast/prometheus/otlp/http_exporter"

begin
  Dir.mktmpdir do |tmpdir|
    config_path = File.join(tmpdir, "prometheus.yml")
    storage_path = File.join(tmpdir, "data")

    File.write(config_path, <<~YAML)
      global:
        scrape_interval: 15s
    YAML

    registry = Fast::Prometheus::Registry.new
    counter = registry.counter(:fpi_otlp_jobs_total, docstring: "OTLP jobs total")
    counter.increment(by: 3)

    nh = registry.native_histogram(:fpi_otlp_duration_seconds, docstring: "OTLP duration")
    nh.observe(0.05)
    nh.observe(0.2)
    nh.observe(1.5)

    prometheus_pid = nil
    outcome = nil

    begin
      Async do
        exporter = Fast::Prometheus::OTLP::HTTPExporter.new(
          endpoint: "http://#{PROMETHEUS_HOST}:#{PROMETHEUS_PORT}/api/v1/otlp",
          registry: registry
        )

        prometheus_pid = spawn(
          PROMETHEUS_BIN,
          "--web.enable-otlp-receiver",
          "--config.file=#{config_path}",
          "--storage.tsdb.path=#{storage_path}",
          "--web.listen-address=#{PROMETHEUS_HOST}:#{PROMETHEUS_PORT}",
          err: File::NULL,
          out: File::NULL
        )

        ready = false
        Timeout.timeout(15) do
          loop do
            begin
              uri = URI("http://#{PROMETHEUS_HOST}:#{PROMETHEUS_PORT}/-/ready")
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

        exported = false
        Timeout.timeout(30) do
          loop do
            exporter.export
            exported = true
            break
          rescue Fast::Prometheus::Error
            sleep 1
          end
        end

        raise "could not export metrics to prometheus" unless exported

        query_url = "http://#{PROMETHEUS_HOST}:#{PROMETHEUS_PORT}/api/v1/query"
        counter_ok = false
        histogram_ok = false

        Timeout.timeout(DEADLINE) do
          loop do
            counter_resp = Timeout.timeout(5) do
              Net::HTTP.get_response(URI("#{query_url}?query=fpi_otlp_jobs_total"))
            end
            if counter_resp.is_a?(Net::HTTPSuccess)
              data = JSON.parse(counter_resp.body)
              counter_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 3
            end

            histogram_resp = Timeout.timeout(5) do
              Net::HTTP.get_response(URI("#{query_url}?query=histogram_count(fpi_otlp_duration_seconds)"))
            end
            if histogram_resp.is_a?(Net::HTTPSuccess)
              data = JSON.parse(histogram_resp.body)
              histogram_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 3
            end

            break if counter_ok && histogram_ok

            sleep POLL_INTERVAL
          end
        end

        exporter.close
        outcome = counter_ok && histogram_ok ? :pass : :fail
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
      puts "CHECK e2e-otlp-http: PASS"
    else
      puts "CHECK e2e-otlp-http: FAIL pushed values never satisfied PromQL expectations"
    end
  end
rescue StandardError => e
  puts "CHECK e2e-otlp-http: FAIL #{e.class}: #{e.message}"
end
