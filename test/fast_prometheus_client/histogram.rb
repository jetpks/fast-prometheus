# frozen_string_literal: true

require "fast_prometheus_client"
require "sus/fixtures/async"

describe FastPrometheusClient::Histogram do
  describe ".new" do
    it "has type :histogram" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t")
      expect(h.type).to be(:==, :histogram)
    end

    it "raises on non-ascending buckets" do
      expect do
        FastPrometheusClient::Histogram.new(:t, docstring: "t", buckets: [1, 3, 2])
      end.to raise_exception(ArgumentError)
    end

    it "raises on :le label" do
      expect do
        FastPrometheusClient::Histogram.new(:t, docstring: "t", labels: [:le])
      end.to raise_exception(FastPrometheusClient::InvalidLabelName)
    end
  end

  describe "#observe" do
    it "handles le inclusivity at exact boundary" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t", buckets: [0.1, 0.5])
      h.observe(0.1)
      expect(h.cumulative_buckets).to be(:==, [[0.1, 1], [0.5, 1], [Float::INFINITY, 1]])
    end

    it "puts overflow value only in +Inf cumulative" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t", buckets: [1, 5])
      h.observe(10)
      expect(h.cumulative_buckets).to be(:==, [[1, 0], [5, 0], [Float::INFINITY, 1]])
    end

    it "produces correct cumulative_buckets for a sequence" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t", buckets: [1, 5, 10])
      h.observe(0.5)
      h.observe(3)
      h.observe(7)
      h.observe(12)
      expect(h.cumulative_buckets).to be(:==, [[1, 1], [5, 2], [10, 3], [Float::INFINITY, 4]])
    end

    it "tracks sum and count" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t", buckets: [1, 5])
      h.observe(0.5)
      h.observe(3)
      expect(h.sum).to be(:==, 3.5)
      expect(h.count).to be(:==, 2)
    end
  end

  describe "#get" do
    it "returns the slot after observations" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t", buckets: [1])
      h.observe(0.5)
      slot = h.get
      expect(slot.count).to be(:==, 1)
      expect(slot.sum).to be(:==, 0.5)
    end

    it "returns nil when no observations" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t")
      expect(h.get).to be_nil
    end
  end

  describe ".linear_buckets" do
    it "produces expected array" do
      expect(FastPrometheusClient::Histogram.linear_buckets(start: 0, width: 10, count: 5))
        .to be(:==, [0.0, 10.0, 20.0, 30.0, 40.0])
    end
  end

  describe ".exponential_buckets" do
    it "produces expected array" do
      expect(FastPrometheusClient::Histogram.exponential_buckets(start: 1, factor: 2, count: 4))
        .to be(:==, [1.0, 2.0, 4.0, 8.0])
    end
  end

  describe "#with_labels" do
    it "binds custom buckets and observes into the parent-visible series" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t", labels: [:path], buckets: [1, 2, 3])
      bound = h.with_labels(path: "/health")
      bound.observe(2.5)
      expect(h.count(labels: { path: "/health" })).to be(:==, 1)
      expect(bound.cumulative_buckets.map(&:first)).to be(:==, [1, 2, 3, Float::INFINITY])
    end
  end

  describe "fiber-safety" do
    include Sus::Fixtures::Async::ReactorContext

    it "accumulates correctly under 500 concurrent observes" do
      h = FastPrometheusClient::Histogram.new(:t, docstring: "t", buckets: [1, 5])

      run_with_timeout do
        tasks = 500.times.map do
          Async do
            h.observe(1)
          end
        end

        tasks.each(&:wait)
      end

      expect(h.count).to be(:==, 500)
    end
  end
end
