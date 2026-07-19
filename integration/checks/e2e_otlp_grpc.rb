# frozen_string_literal: true

# E2E: push metrics via OTLP gRPC from the installed gem to an in-process
# async-grpc server (no real collector). Pattern adapted from
# test/fast/prometheus/otlp/grpc_exporter.rb, without sus.

require "async"
require "async/http/endpoint"
require "async/http/server"

require "fast/prometheus"
require "fast/prometheus/otlp/grpc_exporter"
require "fast/prometheus/otlp/service_interface"
require "async/grpc/dispatcher"
require "async/grpc/service"

HOST = "127.0.0.1"
PORT = 19_407

begin
  captured_requests = []

  test_service = Class.new(Async::GRPC::Service) do
    define_method(:export) do |input, output, _call|
      captured_requests << input.read
      output.write(Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceResponse.new)
    end
  end.new(
    Fast::Prometheus::OTLP::MetricsServiceInterface,
    "opentelemetry.proto.collector.metrics.v1.MetricsService"
  )

  dispatcher = Async::GRPC::Dispatcher.new(services: {
                                             "opentelemetry.proto.collector.metrics.v1.MetricsService" => test_service
                                           })

  endpoint = Async::HTTP::Endpoint.parse("http://#{HOST}:#{PORT}", protocol: Async::HTTP::Protocol::HTTP2)

  registry = Fast::Prometheus::Registry.new
  registry.counter(:otlp_grpc_jobs_total, docstring: "Jobs").increment(by: 3)
  registry.native_histogram(:otlp_grpc_lat_seconds, docstring: "Latency").observe(1.5)

  Async do
    bound = endpoint.bound
    server = Async::HTTP::Server.new(dispatcher, bound, protocol: endpoint.protocol, scheme: endpoint.scheme)
    server_task = server.run

    exporter = Fast::Prometheus::OTLP::GRPCExporter.new(endpoint: "http://#{HOST}:#{PORT}", registry: registry)
    exporter.export
    exporter.close

    server_task.stop
    bound.close
  end

  unless captured_requests.length == 1
    raise "expected exactly 1 captured export request, got #{captured_requests.length}"
  end

  req = captured_requests.first
  metrics = req.resource_metrics.first.scope_metrics.first.metrics
  names = metrics.map(&:name)
  unless names.include?("otlp_grpc_jobs_total")
    raise "jobs_total metric missing from exported request: #{names.inspect}"
  end
  unless names.include?("otlp_grpc_lat_seconds")
    raise "lat_seconds metric missing from exported request: #{names.inspect}"
  end

  lat = metrics.find { |m| m.name == "otlp_grpc_lat_seconds" }
  if lat.exponential_histogram.data_points.empty?
    raise "exported native histogram has no exponential_histogram data points"
  end

  puts "CHECK e2e-otlp-grpc: PASS"
rescue StandardError => e
  puts "CHECK e2e-otlp-grpc: FAIL #{e.class}: #{e.message}"
end
