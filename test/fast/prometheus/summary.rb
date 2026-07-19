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
      value = summary.get
      expect(value.sum).to be(:==, 4.0)
      expect(value.count).to be(:==, 2)
    end

    it "keeps labeled series independent" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      summary.observe(1.0, labels: { method: "get" })
      summary.observe(2.0, labels: { method: "post" })
      expect(summary.get(labels: { method: "get" }).sum).to be(:==, 1.0)
      expect(summary.get(labels: { method: "post" }).sum).to be(:==, 2.0)
    end

    it "returns nil for unobserved label set" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      expect(summary.get(labels: { method: "get" })).to be_nil
    end
  end

  describe "#with_labels" do
    it "binds an observe that accumulates sum/count on the parent" do
      summary = Fast::Prometheus::Summary.new(:t, docstring: "t", labels: [:method])
      bound = summary.with_labels(method: "get")
      bound.observe(2.0)
      value = summary.get(labels: { method: "get" })
      expect(value.sum).to be(:==, 2.0)
      expect(value.count).to be(:==, 1)
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

      value = summary.get
      expect(value.count).to be(:==, 500)
      expect(value.sum).to be(:==, 500.0)
    end
  end
end
