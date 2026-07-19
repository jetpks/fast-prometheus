# frozen_string_literal: true

require "fast_prometheus_client"
require "sus/fixtures/async"

describe FastPrometheusClient::Summary do
  describe ".new" do
    it "has type :summary" do
      expect(FastPrometheusClient::Summary.new(:t, docstring: "t").type).to be(:==, :summary)
    end

    it "rejects :quantile as a declared label" do
      expect do
        FastPrometheusClient::Summary.new(:t, docstring: "t", labels: [:quantile])
      end.to raise_exception(FastPrometheusClient::InvalidLabelName)
    end

    it "accepts other labels" do
      expect do
        FastPrometheusClient::Summary.new(:t, docstring: "t", labels: [:method])
      end.not.to raise_exception
    end
  end

  describe "#observe" do
    it "accumulates sum and count" do
      summary = FastPrometheusClient::Summary.new(:t, docstring: "t")
      summary.observe(2.5)
      summary.observe(1.5)
      value = summary.get
      expect(value.sum).to be(:==, 4.0)
      expect(value.count).to be(:==, 2)
    end

    it "keeps labeled series independent" do
      summary = FastPrometheusClient::Summary.new(:t, docstring: "t", labels: [:method])
      summary.observe(1.0, labels: { method: "get" })
      summary.observe(2.0, labels: { method: "post" })
      expect(summary.get(labels: { method: "get" }).sum).to be(:==, 1.0)
      expect(summary.get(labels: { method: "post" }).sum).to be(:==, 2.0)
    end

    it "returns nil for unobserved label set" do
      summary = FastPrometheusClient::Summary.new(:t, docstring: "t", labels: [:method])
      expect(summary.get(labels: { method: "get" })).to be_nil
    end
  end

  describe "fiber-safety" do
    include Sus::Fixtures::Async::ReactorContext

    it "accumulates correctly under 500 concurrent observes" do
      summary = FastPrometheusClient::Summary.new(:t, docstring: "t")

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
