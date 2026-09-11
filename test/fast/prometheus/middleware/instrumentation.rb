# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/middleware/instrumentation"
require "sus/fixtures/async/http/server_context"

describe Fast::Prometheus::Middleware::Instrumentation do
  include Sus::Fixtures::Async::HTTP::ServerContext

  let(:registry) { Fast::Prometheus::Registry.new }
  let(:delegate) { Protocol::HTTP::Middleware::HelloWorld }

  def middleware
    Fast::Prometheus::Middleware::Instrumentation.new(delegate, registry: registry)
  end

  describe "normal request" do
    it "increments counter and observes histogram" do
      request = Protocol::HTTP::Request["GET", "/hello"]
      response = client.call(request)
      response.read
      response.close

      counter = registry.get(:http_server_requests_total)
      expect(counter.get(labels: { method: "GET", status: "200" })).to be(:==, 1.0)

      histogram = registry.get(:http_server_request_duration_seconds)
      expect(histogram.count(labels: { method: "GET", status: "200" })).to be(:==, 1)
      expect(histogram.sum(labels: { method: "GET", status: "200" })).to be(:>, 0.0)
    end
  end

  describe "native: true" do
    let(:registry) { Fast::Prometheus::Registry.new }

    def middleware
      Fast::Prometheus::Middleware::Instrumentation.new(delegate, registry: registry, native: true)
    end

    it "registers a NativeHistogram" do
      request = Protocol::HTTP::Request["GET", "/hello"]
      response = client.call(request)
      response.read
      response.close

      metric = registry.get(:http_server_request_duration_seconds)
      expect(metric).to be(:instance_of?, Fast::Prometheus::NativeHistogram)
    end
  end

  describe "raising delegate" do
    it "records status 500 and re-raises" do
      registry = Fast::Prometheus::Registry.new
      delegate = Protocol::HTTP::Middleware.for do |_request|
        raise "boom"
      end
      middleware = Fast::Prometheus::Middleware::Instrumentation.new(delegate, registry: registry)

      request = Protocol::HTTP::Request["GET", "/error"]
      expect { middleware.call(request) }.to raise_exception(RuntimeError, message: be == "boom")

      counter = registry.get(:http_server_requests_total)
      expect(counter.get(labels: { method: "GET", status: "500" })).to be(:==, 1.0)
    end

    it "propagates the delegate's exception even when recording fails" do
      registry = Fast::Prometheus::Registry.new
      registry.counter(:http_server_requests_total, docstring: "x", labels: [:path])
      delegate = Protocol::HTTP::Middleware.for do |_request|
        raise "boom"
      end
      middleware = Fast::Prometheus::Middleware::Instrumentation.new(delegate, registry: registry)

      request = Protocol::HTTP::Request["GET", "/error"]
      expect { middleware.call(request) }.to raise_exception(RuntimeError, message: be == "boom")
    end
  end

  describe "concurrent construction" do
    it "registers each metric exactly once and raises nothing" do
      registry = Fast::Prometheus::Registry.new

      threads = 8.times.map do
        Thread.new { Fast::Prometheus::Middleware::Instrumentation.new(delegate, registry: registry) }
      end
      threads.each(&:value)

      names = %i[http_server_request_duration_seconds http_server_requests_total]
      expect(registry.metrics.map(&:name).sort).to be(:==, names)
    end
  end
end
