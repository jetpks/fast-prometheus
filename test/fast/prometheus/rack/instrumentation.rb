# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/rack/instrumentation"
require "rack/lint"
require "rack/mock_request"

describe Fast::Prometheus::Rack::Instrumentation do
  let(:registry) { Fast::Prometheus::Registry.new }
  let(:delegate) { ->(_env) { [200, { "content-type" => "text/plain" }, ["hello"]] } }

  def middleware
    Fast::Prometheus::Rack::Instrumentation.new(::Rack::Lint.new(delegate), registry: registry)
  end

  def request
    ::Rack::MockRequest.new(::Rack::Lint.new(middleware))
  end

  describe "normal request" do
    it "increments counter and observes histogram" do
      response = request.get("/hello")
      expect(response.status).to be(:==, 200)

      counter = registry.get(:http_server_requests_total)
      expect(counter.get(labels: { method: "GET", status: "200" })).to be(:==, 1.0)

      histogram = registry.get(:http_server_request_duration_seconds)
      expect(histogram.count(labels: { method: "GET", status: "200" })).to be(:==, 1)
      expect(histogram.sum(labels: { method: "GET", status: "200" })).to be(:>, 0.0)
    end
  end

  describe "native: true" do
    def middleware
      Fast::Prometheus::Rack::Instrumentation.new(::Rack::Lint.new(delegate), registry: registry, native: true)
    end

    it "registers a NativeHistogram" do
      request.get("/hello")

      metric = registry.get(:http_server_request_duration_seconds)
      expect(metric).to be(:instance_of?, Fast::Prometheus::NativeHistogram)
    end
  end

  describe "raising delegate" do
    it "records status 500 and re-raises" do
      registry = Fast::Prometheus::Registry.new
      raising_delegate = ->(_env) { raise "boom" }
      middleware = Fast::Prometheus::Rack::Instrumentation.new(raising_delegate, registry: registry)

      raised = false
      begin
        middleware.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/error" })
      rescue RuntimeError => e
        raised = true
        expect(e.message).to be(:==, "boom")
      end
      expect(raised).to be(:==, true)

      counter = registry.get(:http_server_requests_total)
      expect(counter.get(labels: { method: "GET", status: "500" })).to be(:==, 1.0)
    end

    it "propagates the delegate's exception even when recording fails" do
      registry = Fast::Prometheus::Registry.new
      registry.counter(:http_server_requests_total, docstring: "x", labels: [:path])
      raising_delegate = ->(_env) { raise "boom" }
      middleware = Fast::Prometheus::Rack::Instrumentation.new(raising_delegate, registry: registry)

      raised = false
      begin
        middleware.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/error" })
      rescue RuntimeError => e
        raised = true
        expect(e.message).to be(:==, "boom")
      end
      expect(raised).to be(:==, true)
    end
  end

  describe "concurrent construction" do
    it "registers each metric exactly once and raises nothing" do
      registry = Fast::Prometheus::Registry.new

      threads = 8.times.map do
        Thread.new { Fast::Prometheus::Rack::Instrumentation.new(delegate, registry: registry) }
      end
      threads.each(&:value)

      names = %i[http_server_request_duration_seconds http_server_requests_total]
      expect(registry.metrics.map(&:name).sort).to be(:==, names)
    end
  end
end
