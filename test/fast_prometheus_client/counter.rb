# frozen_string_literal: true

require "fast_prometheus_client"
require "sus/fixtures/async"

describe FastPrometheusClient::Counter do
  let(:counter) { FastPrometheusClient::Counter.new(:requests, docstring: "Request count") }

  it "reports type :counter" do
    expect(counter.type).to be(:==, :counter)
  end

  describe "#increment" do
    it "increments by 1 by default" do
      counter.increment
      expect(counter.get).to be(:==, 1.0)
    end

    it "increments by given amount" do
      counter.increment(by: 5)
      expect(counter.get).to be(:==, 5.0)
    end

    it "accumulates across calls" do
      counter.increment
      counter.increment(by: 3)
      expect(counter.get).to be(:==, 4.0)
    end

    it "raises ArgumentError for negative by" do
      expect { counter.increment(by: -1) }.to raise_exception(ArgumentError)
    end

    it "stores values as Float" do
      counter.increment(by: 1)
      expect(counter.get).to be(:==, 1.0)
    end
  end

  describe "labeled series" do
    let(:labeled) { FastPrometheusClient::Counter.new(:requests, docstring: "Count", labels: [:method]) }

    it "maintains independent series" do
      labeled.increment(labels: { method: "get" })
      labeled.increment(by: 3, labels: { method: "post" })
      expect(labeled.get(labels: { method: "get" })).to be(:==, 1.0)
      expect(labeled.get(labels: { method: "post" })).to be(:==, 3.0)
    end
  end

  describe "#get" do
    it "returns 0.0 for untouched series" do
      bound = counter.with_labels
      expect(bound.get).to be(:==, 0.0)
    end

    it "does not create series on get" do
      bound = counter.with_labels
      bound.get
      expect(bound.values).to be(:==, {})
    end
  end

  describe "#with_labels" do
    it "increments same series as parent" do
      bound = counter.with_labels
      bound.increment
      expect(counter.get).to be(:==, 1.0)
    end
  end

  describe "fiber-safety" do
    include Sus::Fixtures::Async::ReactorContext

    it "handles 1000 concurrent increments" do
      bound = counter.with_labels

      run_with_timeout do
        tasks = 1000.times.map do
          Async do
            bound.increment
          end
        end

        tasks.each(&:wait)
      end

      expect(counter.get).to be(:==, 1000.0)
    end
  end
end
