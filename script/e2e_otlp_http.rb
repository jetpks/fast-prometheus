#!/usr/bin/env ruby
# frozen_string_literal: true

# E2E: push metrics via OTLP HTTP to a real Prometheus instance,
# verify they appear in PromQL queries.

require "tmpdir"
require "json"
require "net/http"
require "timeout"

require "async"
require "async/http/endpoint"

require "fast_prometheus_client"
require "fast_prometheus_client/otlp/http_exporter"

PROMETHEUS_BIN = "/opt/homebrew/bin/prometheus"
PROMETHEUS_HOST = "127.0.0.1"
PROMETHEUS_PORT = 19_397
POLL_INTERVAL = 1
DEADLINE = 90

Dir.mktmpdir do |tmpdir|
  config_path = File.join(tmpdir, "prometheus.yml")
  storage_path = File.join(tmpdir, "data")

  File.write(config_path, <<~YAML)
    global:
      scrape_interval: 15s
  YAML

  registry = FastPrometheusClient::Registry.new
  counter = registry.counter(:fpc_otlp_jobs_total, docstring: "OTLP jobs total")
  counter.increment(by: 3)

  nh = registry.native_histogram(:fpc_otlp_duration_seconds, docstring: "OTLP duration")
  nh.observe(0.05)
  nh.observe(0.2)
  nh.observe(1.5)

  prometheus_pid = nil
  last_counter_response = nil
  last_histogram_response = nil

  begin
    Async do
      exporter = FastPrometheusClient::OTLP::HTTPExporter.new(
        endpoint: "http://#{PROMETHEUS_HOST}:#{PROMETHEUS_PORT}/api/v1/otlp",
        registry: registry
      )

      begin
        prometheus_pid = spawn(
          PROMETHEUS_BIN,
          "--web.enable-otlp-receiver",
          "--config.file=#{config_path}",
          "--storage.tsdb.path=#{storage_path}",
          "--web.listen-address=#{PROMETHEUS_HOST}:#{PROMETHEUS_PORT}",
          err: File::NULL,
          out: File::NULL
        )
      rescue Errno::ENOENT
        puts "ERROR: #{PROMETHEUS_BIN} not found"
        exit 1
      end

      # Wait for Prometheus to be ready
      ready = false
      Timeout.timeout(15) do
        loop do
          uri = URI("http://#{PROMETHEUS_HOST}:#{PROMETHEUS_PORT}/-/ready")
          response = Net::HTTP.get_response(uri)
          if response.is_a?(Net::HTTPSuccess)
            ready = true
            break
          end
        rescue Errno::ECONNREFUSED
          # Prometheus not ready yet
        end
        sleep POLL_INTERVAL
      end

      unless ready
        puts "ERROR: Prometheus did not become ready in time"
        exit 1
      end

      # Export metrics (retry while Prometheus boots its OTLP receiver)
      exported = false
      Timeout.timeout(30) do
        loop do
          exporter.export
          exported = true
          break
        rescue FastPrometheusClient::Error
          sleep 1
        end
      end

      unless exported
        puts "ERROR: Could not export metrics to Prometheus"
        exit 1
      end

      # Poll for metrics via PromQL
      query_url = "http://#{PROMETHEUS_HOST}:#{PROMETHEUS_PORT}/api/v1/query"
      counter_ok = false
      histogram_ok = false

      Timeout.timeout(DEADLINE) do
        loop do
          counter_resp = Timeout.timeout(5) do
            uri = URI("#{query_url}?query=fpc_otlp_jobs_total")
            Net::HTTP.get_response(uri)
          end
          last_counter_response = counter_resp.body

          if counter_resp.is_a?(Net::HTTPSuccess)
            data = JSON.parse(counter_resp.body)
            counter_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 3
          end

          histogram_resp = Timeout.timeout(5) do
            uri = URI("#{query_url}?query=histogram_count(fpc_otlp_duration_seconds)")
            Net::HTTP.get_response(uri)
          end
          last_histogram_response = histogram_resp.body

          if histogram_resp.is_a?(Net::HTTPSuccess)
            data = JSON.parse(histogram_resp.body)
            histogram_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 3
          end

          break if counter_ok && histogram_ok

          sleep POLL_INTERVAL
        end
      end

      exporter.close

      if counter_ok && histogram_ok
        puts "E2E_OK"
      else
        puts "ERROR: Queries did not return expected values"
        puts "Counter response: #{last_counter_response}"
        puts "Histogram response: #{last_histogram_response}"
        exit 1
      end
    end
  ensure
    if prometheus_pid
      begin
        Process.kill("TERM", prometheus_pid)
      rescue Errno::EPERM, Errno::ESRCH
        # Process already gone
      end
      begin
        Process.wait(prometheus_pid)
      rescue Errno::ECHILD
        # Process already reaped
      end
    end
  end
end
