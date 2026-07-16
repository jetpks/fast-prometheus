# frozen_string_literal: true

require "fast_prometheus_client"

describe FastPrometheusClient::Formats::Text do
  describe "CONTENT_TYPE" do
    it "is text/plain; version=0.0.4; charset=utf-8" do
      expect(FastPrometheusClient::Formats::Text::CONTENT_TYPE)
        .to be(:==, "text/plain; version=0.0.4; charset=utf-8")
    end
  end

  describe ".render" do
    it "renders a counter" do
      registry = FastPrometheusClient::Registry.new
      registry.counter(:requests_total, docstring: "Total requests").increment(by: 42)
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP requests_total Total requests
        # TYPE requests_total counter
        requests_total 42.0
      OUTPUT
      )
    end

    it "renders a counter with labels" do
      registry = FastPrometheusClient::Registry.new
      c = registry.counter(:requests_total, docstring: "Total requests", labels: [:method])
      c.increment(labels: { method: "get" })
      c.increment(by: 3, labels: { method: "post" })
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP requests_total Total requests
        # TYPE requests_total counter
        requests_total{method="get"} 1.0
        requests_total{method="post"} 3.0
      OUTPUT
      )
    end

    it "renders a gauge" do
      registry = FastPrometheusClient::Registry.new
      registry.gauge(:temperature_celsius, docstring: "Temperature").set(20.5)
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP temperature_celsius Temperature
        # TYPE temperature_celsius gauge
        temperature_celsius 20.5
      OUTPUT
      )
    end

    it "renders a histogram with buckets, sum, and count" do
      registry = FastPrometheusClient::Registry.new
      h = registry.histogram(:request_duration, docstring: "Request duration", buckets: [0.1, 0.5, 1.0])
      h.observe(0.03)
      h.observe(0.3)
      h.observe(0.7)
      h.observe(2.0)
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP request_duration Request duration
        # TYPE request_duration histogram
        request_duration_bucket{le="0.1"} 1
        request_duration_bucket{le="0.5"} 2
        request_duration_bucket{le="1.0"} 3
        request_duration_bucket{le="+Inf"} 4
        request_duration_sum 3.03
        request_duration_count 4
      OUTPUT
      )
    end

    it "renders a summary with sum and count" do
      registry = FastPrometheusClient::Registry.new
      s = registry.summary(:response_time, docstring: "Response time")
      s.observe(1.5)
      s.observe(2.5)
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP response_time Response time
        # TYPE response_time summary
        response_time_sum 4.0
        response_time_count 2
      OUTPUT
      )
    end

    it "omits native_histogram entirely" do
      registry = FastPrometheusClient::Registry.new
      registry.counter(:up, docstring: "Up").increment
      registry.native_histogram(:native, docstring: "Native").observe(1.0)
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP up Up
        # TYPE up counter
        up 1.0
      OUTPUT
      )
    end

    it "escapes backslashes and newlines in docstrings" do
      registry = FastPrometheusClient::Registry.new
      registry.counter(:escaped, docstring: "back\\slash\nnewline").increment
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP escaped back\\\\slash\\nnewline
        # TYPE escaped counter
        escaped 1.0
      OUTPUT
      )
    end

    it "escapes backslashes, quotes, and newlines in label values" do
      registry = FastPrometheusClient::Registry.new
      c = registry.counter(:labeled, docstring: "Labeled", labels: [:tag])
      c.increment(labels: { tag: "has\\slash" })
      c.increment(labels: { tag: 'has"quote' })
      c.increment(labels: { tag: "has\nnewline" })
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP labeled Labeled
        # TYPE labeled counter
        labeled{tag="has\\\\slash"} 1.0
        labeled{tag="has\\"quote"} 1.0
        labeled{tag="has\\nnewline"} 1.0
      OUTPUT
      )
    end

    it "renders multiple metrics" do
      registry = FastPrometheusClient::Registry.new
      registry.counter(:a, docstring: "A").increment
      registry.gauge(:b, docstring: "B").set(1)
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP a A
        # TYPE a counter
        a 1.0
        # HELP b B
        # TYPE b gauge
        b 1.0
      OUTPUT
      )
    end

    it "renders Float::INFINITY boundary as +Inf" do
      registry = FastPrometheusClient::Registry.new
      h = registry.histogram(:h, docstring: "H", buckets: [1.0])
      h.observe(0.5)
      output = FastPrometheusClient::Formats::Text.render(registry.collect)
      expect(output).to be(:==, <<~OUTPUT
        # HELP h H
        # TYPE h histogram
        h_bucket{le="1.0"} 1
        h_bucket{le="+Inf"} 1
        h_sum 0.5
        h_count 1
      OUTPUT
      )
    end
  end
end
