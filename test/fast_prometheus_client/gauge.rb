# frozen_string_literal: true

require "fast_prometheus_client"
require "sus/fixtures/async"

describe FastPrometheusClient::Gauge do
  let(:gauge) { FastPrometheusClient::Gauge.new(:temperature, docstring: "Temperature") }

  it "reports type :gauge" do
    expect(gauge.type).to be(:==, :gauge)
  end

  describe "#set" do
    it "sets an integer value" do
      gauge.set(42)
      expect(gauge.get).to be(:==, 42.0)
    end

    it "sets a float value" do
      gauge.set(42.5)
      expect(gauge.get).to be(:==, 42.5)
    end

    it "sets a negative value" do
      gauge.set(-10)
      expect(gauge.get).to be(:==, -10.0)
    end

    it "overwrites previous value" do
      gauge.set(100)
      gauge.set(50)
      expect(gauge.get).to be(:==, 50.0)
    end
  end

  describe "#increment" do
    it "increments by 1 by default" do
      gauge.increment
      expect(gauge.get).to be(:==, 1.0)
    end

    it "increments by given amount" do
      gauge.increment(by: 5)
      expect(gauge.get).to be(:==, 5.0)
    end

    it "allows negative increment" do
      gauge.set(10)
      gauge.increment(by: -3)
      expect(gauge.get).to be(:==, 7.0)
    end

    it "raises ArgumentError for non-numeric by" do
      expect { gauge.increment(by: "x") }.to raise_exception(ArgumentError)
    end
  end

  describe "#decrement" do
    it "decrements by 1 by default" do
      gauge.set(10)
      gauge.decrement
      expect(gauge.get).to be(:==, 9.0)
    end

    it "decrements by given amount" do
      gauge.set(10)
      gauge.decrement(by: 3)
      expect(gauge.get).to be(:==, 7.0)
    end

    it "allows negative decrement (increases)" do
      gauge.set(10)
      gauge.decrement(by: -3)
      expect(gauge.get).to be(:==, 13.0)
    end

    it "raises ArgumentError for non-numeric by" do
      expect { gauge.decrement(by: nil) }.to raise_exception(ArgumentError)
    end
  end

  describe "labeled series" do
    let(:labeled) { FastPrometheusClient::Gauge.new(:temp, docstring: "Temp", labels: [:zone]) }

    it "maintains independent series" do
      labeled.set(20, labels: { zone: "a" })
      labeled.set(30, labels: { zone: "b" })
      expect(labeled.get(labels: { zone: "a" })).to be(:==, 20.0)
      expect(labeled.get(labels: { zone: "b" })).to be(:==, 30.0)
    end
  end

  describe "#get" do
    it "returns 0.0 for untouched series" do
      bound = gauge.with_labels
      expect(bound.get).to be(:==, 0.0)
    end

    it "does not create series on get" do
      bound = gauge.with_labels
      bound.get
      expect(bound.values).to be(:==, {})
    end
  end

  describe "#with_labels" do
    it "increments same series as parent" do
      bound = gauge.with_labels
      bound.increment
      expect(gauge.get).to be(:==, 1.0)
    end
  end

  describe "fiber-safety" do
    include Sus::Fixtures::Async::ReactorContext

    it "handles 1000 concurrent increments" do
      bound = gauge.with_labels

      run_with_timeout do
        tasks = 1000.times.map do
          Async do
            bound.increment
          end
        end

        tasks.each(&:wait)
      end

      expect(gauge.get).to be(:==, 1000.0)
    end
  end
end
