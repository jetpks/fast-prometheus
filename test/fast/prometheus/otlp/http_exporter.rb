# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/otlp/http_exporter"
require "async/http/server"
require "sus/fixtures/async"

describe Fast::Prometheus::OTLP::HTTPExporter do
  include Sus::Fixtures::Async::ReactorContext

  let(:registry) { Fast::Prometheus::Registry.new }
  let(:counter) { registry.counter(:requests_total, docstring: "Requests") }

  def make_server(port)
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}")
    bound = endpoint.bound
    yield bound, endpoint, port
  ensure
    bound&.close
  end

  it "posts protobuf to /v1/metrics with correct content-type" do
    counter.increment(by: 5)

    captured = {}
    port = 19_400

    make_server(port) do |bound, endpoint, port|
      server = Async::HTTP::Server.new(
        Async::HTTP::Server.for(endpoint) do |request|
          captured[:path] = request.path
          captured[:headers] = request.headers
          captured[:body] = request.body.read
          Protocol::HTTP::Response[200, {}, ["ok"]]
        end,
        bound,
        protocol: endpoint.protocol,
        scheme: endpoint.scheme
      )

      server_task = server.run

      exporter = Fast::Prometheus::OTLP::HTTPExporter.new(
        endpoint: "http://127.0.0.1:#{port}",
        registry: registry
      )

      exporter.export
      exporter.close

      server_task.stop
    end

    expect(captured[:path]).to be(:==, "/v1/metrics")
    expect(captured[:headers]["content-type"]).to be(:==, "application/x-protobuf")

    req = Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest.decode(captured[:body])
    metric = req.resource_metrics.first.scope_metrics.first.metrics.first
    expect(metric.name).to be(:==, "requests_total")
    expect(metric.sum.data_points.first.as_double).to be(:==, 5.0)
  end

  it "raises Error on 500 response" do
    counter.increment

    port = 19_401

    make_server(port) do |bound, endpoint, port|
      server = Async::HTTP::Server.new(
        Async::HTTP::Server.for(endpoint) do
          Protocol::HTTP::Response[500, {}, ["internal error"]]
        end,
        bound,
        protocol: endpoint.protocol,
        scheme: endpoint.scheme
      )

      server_task = server.run

      exporter = Fast::Prometheus::OTLP::HTTPExporter.new(
        endpoint: "http://127.0.0.1:#{port}",
        registry: registry
      )

      begin
        expect { exporter.export }.to raise_exception(Fast::Prometheus::Error)
      ensure
        exporter.close
        server_task.stop
      end
    end
  end

  it "includes custom headers" do
    counter.increment

    port = 19_402
    captured_headers = nil

    make_server(port) do |bound, endpoint, port|
      server = Async::HTTP::Server.new(
        Async::HTTP::Server.for(endpoint) do |request|
          captured_headers = request.headers
          Protocol::HTTP::Response[200, {}, ["ok"]]
        end,
        bound,
        protocol: endpoint.protocol,
        scheme: endpoint.scheme
      )

      server_task = server.run

      exporter = Fast::Prometheus::OTLP::HTTPExporter.new(
        endpoint: "http://127.0.0.1:#{port}",
        registry: registry,
        headers: { "X-Trace-ID" => "abc123" }
      )

      begin
        exporter.export
        expect(captured_headers["x-trace-id"].to_s).to be(:==, "abc123")
      ensure
        exporter.close
        server_task.stop
      end
    end
  end
end
