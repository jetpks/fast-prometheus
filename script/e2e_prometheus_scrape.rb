#!/usr/bin/env ruby
# frozen_string_literal: true

# E2E harness: serve metrics via the Exporter middleware, scrape with real Prometheus,
# verify PromQL queries for counter and native histogram.

require "tmpdir"
require "json"
require "net/http"
require "timeout"

require "async"
require "async/http/endpoint"
require "async/http/server"

require "fast_prometheus_client"
require "fast_prometheus_client/middleware/exporter"

PROMETHEUS_BIN = "/opt/homebrew/bin/prometheus"
METRICS_HOST = "127.0.0.1"
METRICS_PORT = 19_394
PROMETHEUS_PORT = 19_395
SCRAPE_INTERVAL = 1
POLL_INTERVAL = 1
DEADLINE = 90

Dir.mktmpdir do |tmpdir|
  config_path = File.join(tmpdir, "prometheus.yml")
  storage_path = File.join(tmpdir, "data")

  # Write Prometheus config
  File.write(config_path, <<~YAML)
    global:
      scrape_interval: #{SCRAPE_INTERVAL}s

    scrape_configs:
      - job_name: "fast_prometheus_client"
        scrape_native_histograms: true
        static_configs:
          - targets: ["#{METRICS_HOST}:#{METRICS_PORT}"]
  YAML

  # Set up registry with test metrics
  registry = FastPrometheusClient::Registry.new
  counter = registry.counter(:fpc_e2e_jobs_total, docstring: "E2E jobs total")
  counter.increment(by: 3)

  nh = registry.native_histogram(:fpc_e2e_duration_seconds, docstring: "E2E duration")
  nh.observe(0.05)
  nh.observe(0.2)
  nh.observe(1.5)

  # Labeled counter
  labeled_counter = registry.counter(
    :fpc_e2e_labeled_jobs_total,
    docstring: "E2E labeled jobs total",
    labels: %i[method]
  )
  labeled_counter.increment(by: 5, labels: { method: "GET" })
  labeled_counter.increment(by: 2, labels: { method: "POST" })

  # Labeled native histogram
  labeled_nh = registry.native_histogram(
    :fpc_e2e_labeled_duration_seconds,
    docstring: "E2E labeled duration",
    labels: %i[endpoint]
  )
  labeled_nh.observe(0.1, labels: { endpoint: "/api" })
  labeled_nh.observe(0.3, labels: { endpoint: "/api" })
  labeled_nh.observe(1.0, labels: { endpoint: "/health" })

  # Build middleware stack
  middleware = FastPrometheusClient::Middleware::Exporter.new(
    Protocol::HTTP::Middleware::NotFound,
    registry: registry
  )

  # Start metrics server
  endpoint = Async::HTTP::Endpoint.parse(
    "http://#{METRICS_HOST}:#{METRICS_PORT}",
    protocol: Async::HTTP::Protocol::HTTP1
  )

  prometheus_pid = nil

  begin
    Async do
      bound = endpoint.bound
      server = Async::HTTP::Server.new(middleware, bound, protocol: endpoint.protocol, scheme: endpoint.scheme)
      server_task = server.run

      # Spawn Prometheus
      prometheus_pid = spawn(
        PROMETHEUS_BIN,
        "--config.file=#{config_path}",
        "--storage.tsdb.path=#{storage_path}",
        "--web.listen-address=#{METRICS_HOST}:#{PROMETHEUS_PORT}",
        err: File::NULL,
        out: File::NULL
      )

      # Wait for Prometheus to be ready
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
            # Prometheus not ready yet
          end
          sleep POLL_INTERVAL
        end
      end

      unless ready
        puts "ERROR: Prometheus did not become ready in time"
        exit 1
      end

      # Poll for metrics
      query_url = "http://#{METRICS_HOST}:#{PROMETHEUS_PORT}/api/v1/query"
      counter_ok = false
      histogram_ok = false
      labeled_counter_ok = false
      labeled_histogram_ok = false
      last_counter_response = nil
      last_histogram_response = nil
      last_labeled_counter_response = nil
      last_labeled_histogram_response = nil

      Timeout.timeout(DEADLINE) do
        loop do
          # Query counter
          counter_resp = Timeout.timeout(5) do
            uri = URI("#{query_url}?query=fpc_e2e_jobs_total")
            Net::HTTP.get_response(uri)
          end
          last_counter_response = counter_resp.body

          if counter_resp.is_a?(Net::HTTPSuccess)
            data = JSON.parse(counter_resp.body)
            counter_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 3
          end

          # Query histogram count
          histogram_resp = Timeout.timeout(5) do
            uri = URI("#{query_url}?query=histogram_count(fpc_e2e_duration_seconds)")
            Net::HTTP.get_response(uri)
          end
          last_histogram_response = histogram_resp.body

          if histogram_resp.is_a?(Net::HTTPSuccess)
            data = JSON.parse(histogram_resp.body)
            histogram_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 3
          end

          # Query labeled counter with label matcher
          labeled_counter_resp = Timeout.timeout(5) do
            uri = URI("#{query_url}?query=fpc_e2e_labeled_jobs_total%7Bmethod%3D%22GET%22%7D")
            Net::HTTP.get_response(uri)
          end
          last_labeled_counter_response = labeled_counter_resp.body

          if labeled_counter_resp.is_a?(Net::HTTPSuccess)
            data = JSON.parse(labeled_counter_resp.body)
            labeled_counter_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 5
          end

          # Query labeled native histogram with label matcher
          labeled_histogram_query = "histogram_count%28fpc_e2e_labeled_duration_seconds%7Bendpoint%3D%22%2Fapi%22%7D%29"
          labeled_histogram_resp = Timeout.timeout(5) do
            uri = URI("#{query_url}?query=#{labeled_histogram_query}")
            Net::HTTP.get_response(uri)
          end
          last_labeled_histogram_response = labeled_histogram_resp.body

          if labeled_histogram_resp.is_a?(Net::HTTPSuccess)
            data = JSON.parse(labeled_histogram_resp.body)
            labeled_histogram_ok = true if data.dig("data", "result", 0, "value", 1).to_f >= 2
          end

          break if counter_ok && histogram_ok && labeled_counter_ok && labeled_histogram_ok

          sleep POLL_INTERVAL
        end
      end

      if counter_ok && histogram_ok
        puts "E2E_OK"
      else
        puts "ERROR: Queries did not return expected values"
        puts "Counter response: #{last_counter_response}"
        puts "Histogram response: #{last_histogram_response}"
        exit 1
      end

      if labeled_counter_ok && labeled_histogram_ok
        puts "E2E_LABELED_OK"
      else
        puts "ERROR: Labeled queries did not return expected values"
        puts "Labeled counter response: #{last_labeled_counter_response}"
        puts "Labeled histogram response: #{last_labeled_histogram_response}"
        exit 1
      end

      # Clean up inside the async block
      server_task.stop
      server_task.wait_all
      bound.close
    end
  ensure
    # Always kill Prometheus
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
