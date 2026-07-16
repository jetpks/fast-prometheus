# frozen_string_literal: true

require "fast_prometheus_client"
require "fast_prometheus_client/middleware/instrumentation"
require "sus/fixtures/async/http/server_context"

describe FastPrometheusClient::Middleware::Instrumentation do
  include Sus::Fixtures::Async::HTTP::ServerContext

  let(:registry) { FastPrometheusClient::Registry.new }
  let(:delegate) { Protocol::HTTP::Middleware::HelloWorld }

  def middleware
    FastPrometheusClient::Middleware::Instrumentation.new(delegate, registry: registry)
  end

  describe "normal request" do
    it "increments counter and observes histogram" do
      request = Protocol::HTTP::Request["GET", "/hello"]
      response = client.call(request)
      response.read
      response.close

      counter = registry.get("http_server_requests_total")
      expect(counter.get(labels: { method: "GET", status: "200" })).to be(:==, 1.0)

      histogram = registry.get("http_server_request_duration_seconds")
      expect(histogram.count(labels: { method: "GET", status: "200" })).to be(:==, 1)
      expect(histogram.sum(labels: { method: "GET", status: "200" })).to be(:>, 0.0)
    end
  end

  describe "native: true" do
    let(:registry) { FastPrometheusClient::Registry.new }

    def middleware
      FastPrometheusClient::Middleware::Instrumentation.new(delegate, registry: registry, native: true)
    end

    it "registers a NativeHistogram" do
      request = Protocol::HTTP::Request["GET", "/hello"]
      response = client.call(request)
      response.read
      response.close

      metric = registry.get("http_server_request_duration_seconds")
      expect(metric).to be(:instance_of?, FastPrometheusClient::NativeHistogram)
    end
  end

  describe "raising delegate" do
    it "records status 500 and re-raises" do
      registry = FastPrometheusClient::Registry.new
      delegate = Protocol::HTTP::Middleware.for do |_request|
        raise "boom"
      end
      middleware = FastPrometheusClient::Middleware::Instrumentation.new(delegate, registry: registry)

      request = Protocol::HTTP::Request["GET", "/error"]
      raised = false
      begin
        middleware.call(request)
      rescue RuntimeError => e
        raised = true
        expect(e.message).to be(:==, "boom")
      end
      expect(raised).to be(:==, true)

      counter = registry.get("http_server_requests_total")
      expect(counter.get(labels: { method: "GET", status: "500" })).to be(:==, 1.0)
    end
  end
end
