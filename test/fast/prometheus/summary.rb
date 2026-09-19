# frozen_string_literal: true

require "fast/prometheus"
require "sus/fixtures/async"

describe Fast::Prometheus::Summary do
  describe ".new" do
    it "has type :summary" do
      expect(Fast::Prometheus::Summary.new(:t, docstring: "t").type).to be(:==, :summary)
    end

    it "rejects :quantile as a declared label" do
      expect do
        Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:quantile])
      end.to raise_exception(Fast::Prometheus::InvalidLabelName)
    end

    it "rejects a String \"quantile\" label" do
      expect do
        Fast::Prometheus::Summary.new(:t, docstring: "t", labels: ["quantile"])
      end.to raise_exception(Fast::Prometheus::InvalidLabelName)
    end

    it "accepts other labels" do
      expect do
        Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      end.not.to raise_exception
    end
  end

  describe "#observe" do
    it "accumulates sum and count" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t")
      summary.observe(2.5)
      summary.observe(1.5)
      expect(summary.get).to be(:==, { "count" => 2, "sum" => 4.0 })
    end

    it "keeps labeled series independent" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      summary.observe(1.0, labels: { method: "get" })
      summary.observe(2.0, labels: { method: "post" })
      expect(summary.get(labels: { method: "get" })["sum"]).to be(:==, 1.0)
      expect(summary.get(labels: { method: "post" })["sum"]).to be(:==, 2.0)
    end

    it "returns a zero-valued hash for unobserved label set" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      expect(summary.get(labels: { method: "get" })).to be(:==, { "count" => 0, "sum" => 0.0 })
    end
  end

  describe "#with_labels" do
    it "binds an observe that accumulates sum/count on the parent" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      bound = summary.with_labels(method: "get")
      bound.observe(2.0)
      expect(summary.get(labels: { method: "get" })).to be(:==, { "count" => 1, "sum" => 2.0 })
    end
  end

  describe "#snapshot_values" do
    it "keys frozen SummaryValues by label set, matching MetricSnapshot.of" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      summary.observe(2.0, labels: { method: "get" })
      value = summary.snapshot_values[["get"]]
      expect(value).to be_a(Fast::Prometheus::SummaryValue)
      expect(value.sum).to be(:==, 2.0)
      expect(value.count).to be(:==, 1)
      expect(value).to be(:==, Fast::Prometheus::MetricSnapshot.of(summary).series.values.first)
    end
  end

  describe "seeding" do
    it "seeds a zero-valued series at construction when fully bound" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t")
      expect(summary.values).to be(:==, { {} => { "count" => 0, "sum" => 0.0 } })
    end

    it "seeds nothing when partially bound" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      expect(summary.values).to be(:==, {})
    end

    it "seeds a fully-bound with_labels child" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      summary.with_labels(method: "get")
      expect(summary.values).to be(:==, { { method: "get" } => { "count" => 0, "sum" => 0.0 } })
    end
  end

  describe "#init_label_set" do
    it "creates an absent series at zero without resetting a live one" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      summary.observe(2.0, labels: { method: "get" })
      summary.init_label_set(method: "get")
      summary.init_label_set(method: "post")
      expect(summary.get(labels: { method: "get" })).to be(:==, { "count" => 1, "sum" => 2.0 })
      expect(summary.get(labels: { method: "post" })).to be(:==, { "count" => 0, "sum" => 0.0 })
    end
  end

  describe "fiber-safety" do
    include Sus::Fixtures::Async::ReactorContext

    it "accumulates correctly under 500 concurrent observes" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t")

      run_with_timeout do
        500.times.map do
          Async do
            summary.observe(1.0)
          end
        end.each(&:wait)
      end

      expect(summary.get).to be(:==, { "count" => 500, "sum" => 500.0 })
    end
  end
end
