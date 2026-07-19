# frozen_string_literal: true

require "fast_prometheus_client"

describe FastPrometheusClient::Registry do
  let(:registry) { FastPrometheusClient::Registry.new }

  describe "#register" do
    it "returns the metric and stores it" do
      counter = FastPrometheusClient::Counter.new(:requests, docstring: "Requests")
      result = registry.register(counter)
      expect(result).to be(:==, counter)
      expect(registry.get(:requests)).to be(:==, counter)
    end

    it "raises DuplicateMetric for same name" do
      registry.register(FastPrometheusClient::Counter.new(:requests, docstring: "Requests"))
      expect { registry.register(FastPrometheusClient::Gauge.new(:requests, docstring: "Dup")) }
        .to raise_exception(FastPrometheusClient::DuplicateMetric)
    end
  end

  describe "#unregister" do
    it "removes the metric by name" do
      counter = FastPrometheusClient::Counter.new(:requests, docstring: "Requests")
      registry.register(counter)
      registry.unregister(:requests)
      expect(registry.get(:requests)).to be_nil
      expect(registry.metrics).to be(:==, [])
    end
  end

  describe "#metrics" do
    it "returns a copy" do
      registry.register(FastPrometheusClient::Counter.new(:requests, docstring: "R"))
      list = registry.metrics
      list << "fake"
      expect(registry.metrics.length).to be(:==, 1)
    end
  end

  describe "convenience constructors" do
    it "counter" do
      c = registry.counter(:req, docstring: "R")
      expect(c.type).to be(:==, :counter)
      expect(registry.get(:req)).to be(:==, c)
    end

    it "gauge" do
      g = registry.gauge(:temp, docstring: "T")
      expect(g.type).to be(:==, :gauge)
    end

    it "histogram" do
      h = registry.histogram(:dur, docstring: "D")
      expect(h.type).to be(:==, :histogram)
    end

    it "summary" do
      s = registry.summary(:size, docstring: "S")
      expect(s.type).to be(:==, :summary)
    end

    it "native_histogram" do
      n = registry.native_histogram(:ndur, docstring: "ND")
      expect(n.type).to be(:==, :native_histogram)
    end
  end

  describe "default registry" do
    it "memoizes a single instance" do
      expect(FastPrometheusClient.registry).to be(:==, FastPrometheusClient.registry)
    end

    it "can be replaced via writer" do
      old = FastPrometheusClient.registry
      new_reg = FastPrometheusClient::Registry.new
      FastPrometheusClient.registry = new_reg
      expect(FastPrometheusClient.registry).to be(:==, new_reg)
      FastPrometheusClient.registry = old
    end
  end
end
