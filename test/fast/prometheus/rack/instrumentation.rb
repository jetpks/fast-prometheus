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

  describe "method label" do
    let(:instrumentation) { Fast::Prometheus::Rack::Instrumentation.new(delegate, registry: registry) }

    def record(method)
      instrumentation.call({ "REQUEST_METHOD" => method, "PATH_INFO" => "/hello" })
    end

    def methods_recorded
      registry.get(:http_server_requests_total).values.keys.map { |labels| labels[:method] }
    end

    it "records an allowlisted method under its own name" do
      allowed = %w[GET HEAD POST PUT DELETE CONNECT OPTIONS TRACE PATCH]
      allowed.each { |method| record(method) }

      expect(methods_recorded).to be(:==, allowed)
    end

    it "collapses every other token to _OTHER, case included" do
      %w[get PROPFIND M1].each { |method| record(method) }

      expect(methods_recorded).to be(:==, ["_OTHER"])
      expect(registry.get(:http_server_requests_total).get(labels: { method: "_OTHER", status: "200" }))
        .to be(:==, 3.0)
    end

    it "folds a BINARY-tagged token into its allowlisted name" do
      record("GET")
      record("GET".b)

      expect(methods_recorded).to be(:==, ["GET"])
      expect(registry.get(:http_server_requests_total).get(labels: { method: "GET", status: "200" })).to be(:==, 2.0)
    end
  end

  describe "pre-registered metrics" do
    it "reuses a metric declaring the same labels" do
      counter = registry.counter(:http_server_requests_total, docstring: "mine", labels: %i[method status])
      instrumentation = Fast::Prometheus::Rack::Instrumentation.new(delegate, registry: registry)
      instrumentation.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/hello" })

      expect(counter.get(labels: { method: "GET", status: "200" })).to be(:==, 1.0)
    end

    it "raises at construction when a metric declares other labels" do
      registry.histogram(:http_server_request_duration_seconds, docstring: "mine", labels: %i[route])

      expect { Fast::Prometheus::Rack::Instrumentation.new(delegate, registry: registry) }
        .to raise_exception(Fast::Prometheus::InvalidLabelSet)
    end

    it "raises at construction when a metric is not the kind its name promises" do
      registry.counter(:http_server_request_duration_seconds, docstring: "mine", labels: %i[method status])

      expect { Fast::Prometheus::Rack::Instrumentation.new(delegate, registry: registry) }
        .to raise_exception(Fast::Prometheus::InvalidMetricType)
    end
  end

  describe "raising delegate" do
    let(:failing_histogram) do
      Class.new(Fast::Prometheus::Histogram) do
        def observe(*, **)
          raise "observe failed"
        end
      end
    end

    it "records status 500 and re-raises" do
      registry = Fast::Prometheus::Registry.new
      raising_delegate = ->(_env) { raise "boom" }
      middleware = Fast::Prometheus::Rack::Instrumentation.new(raising_delegate, registry: registry)
      env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/error" }

      expect { middleware.call(env) }.to raise_exception(RuntimeError, message: be(:==, "boom"))

      counter = registry.get(:http_server_requests_total)
      expect(counter.get(labels: { method: "GET", status: "500" })).to be(:==, 1.0)
    end

    it "propagates the delegate's exception even when recording fails" do
      registry = Fast::Prometheus::Registry.new
      # A duration metric of the right kind and labels whose observation fails,
      # so recording the 500 raises on top of the delegate's exception.
      registry.register(failing_histogram.new(:http_server_request_duration_seconds,
                                              docstring: "x", labels: %i[method status]))
      raising_delegate = ->(_env) { raise "boom" }
      middleware = Fast::Prometheus::Rack::Instrumentation.new(raising_delegate, registry: registry)
      env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/error" }

      expect { middleware.call(env) }.to raise_exception(RuntimeError, message: be(:==, "boom"))
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
