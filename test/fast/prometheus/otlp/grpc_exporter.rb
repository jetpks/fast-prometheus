# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/otlp/grpc_exporter"
require "fast/prometheus/otlp/service_interface"
require "async/grpc/dispatcher"
require "async/grpc/service"
require "sus/fixtures/async/http"

describe Fast::Prometheus::OTLP::GRPCExporter do
  include Sus::Fixtures::Async::HTTP::ServerContext

  let(:registry) { Fast::Prometheus::Registry.new }
  let(:captured_requests) { [] }

  let(:test_service) do
    captured = captured_requests
    Class.new(Async::GRPC::Service) do
      define_method(:export) do |input, output, _call|
        request = input.read
        captured << request
        output.write(Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceResponse.new)
      end
    end.new(
      Fast::Prometheus::OTLP::MetricsServiceInterface,
      "opentelemetry.proto.collector.metrics.v1.MetricsService"
    )
  end

  let(:app) do
    Async::GRPC::Dispatcher.new(services: {
                                  "opentelemetry.proto.collector.metrics.v1.MetricsService" => test_service
                                })
  end

  let(:protocol) { Async::HTTP::Protocol::HTTP2 }

  let(:exporter) do
    Fast::Prometheus::OTLP::GRPCExporter.new(
      endpoint: bound_url,
      registry: registry
    )
  end

  it "exports metrics via gRPC" do
    registry.counter(:my_counter, docstring: "A counter").increment(by: 3)
    exporter.export
    expect(captured_requests.length).to be(:==, 1)
    req = captured_requests.first
    expect(req.resource_metrics.first.scope_metrics.first.metrics.length).to be(:==, 1)
    expect(req.resource_metrics.first.scope_metrics.first.metrics.first.name).to be(:==, "my_counter")
  end

  it "exports counter and native histogram together" do
    registry.counter(:jobs_total, docstring: "Jobs").increment(by: 3)
    registry.native_histogram(:lat_seconds, docstring: "Latency").observe(1.5)
    exporter.export

    req = captured_requests.first
    metrics = req.resource_metrics.first.scope_metrics.first.metrics
    names = metrics.map(&:name)
    expect(names).to be(:include?, "jobs_total")
    expect(names).to be(:include?, "lat_seconds")

    # Verify exponential histogram data point positive offset
    lat = metrics.find { |m| m.name == "lat_seconds" }
    dp = lat.exponential_histogram.data_points.first
    expect(dp.positive.offset).to be(:==, 4)
  end

  it "closes cleanly" do
    exporter.close
  end
end
