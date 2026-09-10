# frozen_string_literal: true

require "fast/prometheus"

describe Fast::Prometheus::Registry do
  let(:registry) { Fast::Prometheus::Registry.new }

  describe "#register" do
    it "returns the metric and stores it" do
      counter = Fast::Prometheus::Counter.new(:requests, docstring: "Requests")
      result = registry.register(counter)
      expect(result).to be(:==, counter)
      expect(registry.get(:requests)).to be(:==, counter)
    end

    it "raises DuplicateMetric for same name" do
      registry.register(Fast::Prometheus::Counter.new(:requests, docstring: "Requests"))
      expect { registry.register(Fast::Prometheus::Gauge.new(:requests, docstring: "Dup")) }
        .to raise_exception(Fast::Prometheus::DuplicateMetric)
    end
  end

  describe "#fetch_or_register" do
    it "returns the existing metric without calling the block" do
      counter = registry.register(Fast::Prometheus::Counter.new(:requests, docstring: "R"))
      called = false
      result = registry.fetch_or_register(:requests) do
        called = true
        Fast::Prometheus::Counter.new(:requests, docstring: "R")
      end
      expect(result).to be(:==, counter)
      expect(called).to be(:==, false)
    end

    it "registers the block's metric when absent" do
      result = registry.fetch_or_register(:requests) { Fast::Prometheus::Counter.new(:requests, docstring: "R") }
      expect(result.name).to be(:==, :requests)
      expect(registry.get(:requests)).to be(:==, result)
    end

    it "raises ArgumentError on a name mismatch" do
      expect do
        registry.fetch_or_register(:requests) { Fast::Prometheus::Counter.new(:other, docstring: "R") }
      end.to raise_exception(ArgumentError)
    end

    it "registers exactly once under concurrent callers for one absent name" do
      threads = 8.times.map do
        Thread.new { registry.fetch_or_register(:requests) { Fast::Prometheus::Counter.new(:requests, docstring: "R") } }
      end
      results = threads.map(&:value)

      expect(results.uniq.length).to be(:==, 1)
      expect(registry.metrics.length).to be(:==, 1)
    end
  end

  describe "#unregister" do
    it "removes the metric by name" do
      counter = Fast::Prometheus::Counter.new(:requests, docstring: "Requests")
      registry.register(counter)
      registry.unregister(:requests)
      expect(registry.get(:requests)).to be_nil
      expect(registry.metrics).to be(:==, [])
    end
  end

  describe "#metrics" do
    it "returns a copy" do
      registry.register(Fast::Prometheus::Counter.new(:requests, docstring: "R"))
      list = registry.metrics
      list << "fake"
      expect(registry.metrics.length).to be(:==, 1)
    end

    it "keeps insertion order stable across an unregister" do
      registry.register(Fast::Prometheus::Counter.new(:a, docstring: "A"))
      registry.register(Fast::Prometheus::Counter.new(:b, docstring: "B"))
      registry.register(Fast::Prometheus::Counter.new(:c, docstring: "C"))
      registry.unregister(:b)
      expect(registry.metrics.map(&:name)).to be(:==, %i[a c])
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
      expect(Fast::Prometheus.registry).to be(:==, Fast::Prometheus.registry)
    end

    it "can be replaced via writer" do
      old = Fast::Prometheus.registry
      new_reg = Fast::Prometheus::Registry.new
      Fast::Prometheus.registry = new_reg
      expect(Fast::Prometheus.registry).to be(:==, new_reg)
      Fast::Prometheus.registry = old
    end
  end
end
