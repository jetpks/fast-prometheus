# frozen_string_literal: true

require "fast_prometheus_client"
require "sus/fixtures/async"

class TestMetric < FastPrometheusClient::Metric
  def type
    :test
  end

  def touch(labels: {})
    key = resolve(labels)
    store[key] = (store[key] || 0.0) + 1.0
  end

  def public_resolve(labels)
    resolve(labels)
  end
end

describe FastPrometheusClient::Metric do
  describe ".new" do
    it "rejects invalid metric name" do
      expect { TestMetric.new("123bad".to_sym, docstring: "help") }.to raise_exception(FastPrometheusClient::InvalidMetricName)
    end

    it "accepts valid metric name" do
      expect { TestMetric.new(:valid_name, docstring: "help") }.not.to raise_exception
    end

    it "rejects nil docstring" do
      expect { TestMetric.new(:valid_name, docstring: nil) }.to raise_exception(ArgumentError)
    end

    it "rejects empty docstring" do
      expect { TestMetric.new(:valid_name, docstring: "") }.to raise_exception(ArgumentError)
    end

    it "rejects bad label name" do
      expect { TestMetric.new(:valid_name, docstring: "help", labels: ["123bad".to_sym]) }.to raise_exception(FastPrometheusClient::InvalidLabelName)
    end

    it "rejects __-prefixed label name" do
      expect { TestMetric.new(:valid_name, docstring: "help", labels: [:__reserved]) }.to raise_exception(FastPrometheusClient::InvalidLabelName)
    end

    it "rejects preset key not in labels" do
      expect do
        TestMetric.new(:valid_name, docstring: "help", labels: [:method], preset_labels: { unknown: "x" })
      end.to raise_exception(FastPrometheusClient::InvalidLabelSet)
    end
  end

  describe "#with_labels" do
    it "raises on unknown label name" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      expect { metric.with_labels(unknown: "get") }.to raise_exception(FastPrometheusClient::InvalidLabelSet)
    end

    it "shares storage with parent" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      bound = metric.with_labels(method: "get")
      bound.touch
      expect(metric.values).to be(:==, { method: "get" } => 1.0)
    end
  end

  describe "#resolve" do
    it "raises on missing label" do
      metric = TestMetric.new(:test, docstring: "help", labels: %i[method status])
      expect { metric.public_resolve(method: "get") }.to raise_exception(FastPrometheusClient::InvalidLabelSet)
    end
  end

  describe "#values" do
    it "returns label-hash keyed data" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      metric.touch(labels: { method: "get" })
      expect(metric.values).to be(:==, { method: "get" } => 1.0)
    end
  end

  describe "fiber-safety" do
    include Sus::Fixtures::Async::ReactorContext

    it "accumulates correctly under 500 concurrent tasks" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      bound = metric.with_labels(method: "get")

      run_with_timeout do
        tasks = 500.times.map do
          Async do
            bound.touch
          end
        end

        tasks.each(&:wait)
      end

      expect(metric.values).to be(:==, { method: "get" } => 500.0)
    end
  end
end
