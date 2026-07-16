# frozen_string_literal: true

require "fast_prometheus_client"

describe FastPrometheusClient::Snapshot do
  let(:registry) { FastPrometheusClient::Registry.new }

  describe "collect with all five metric types" do
    let(:counter) { registry.counter(:req_total, docstring: "Requests") }
    let(:gauge) { registry.gauge(:temp, docstring: "Temperature", labels: [:sensor]) }
    let(:histogram) { registry.histogram(:dur, docstring: "Duration") }
    let(:summary) { registry.summary(:size, docstring: "Size") }
    let(:native_histogram) { registry.native_histogram(:ndur, docstring: "Native duration") }

    before do
      counter.increment(by: 5)
      gauge.set(22.5, labels: { sensor: "cpu" })
      histogram.observe(0.5)
      histogram.observe(1.5)
      summary.observe(100)
      summary.observe(200)
      native_histogram.observe(1.0)
      native_histogram.observe(-2.0)
    end

    let(:snapshot) { registry.collect }

    it "has 5 metrics and a timestamp" do
      expect(snapshot.metrics.length).to be(:==, 5)
      expect(snapshot.taken_at).to be_a(Time)
    end

    describe "counter series" do
      let(:metric) { snapshot.metrics.find { |m| m.name == :req_total } }

      it "has correct shape" do
        expect(metric.type).to be(:==, :counter)
        expect(metric.series.length).to be(:==, 1)
        expect(metric.series.first.labels).to be(:==, {})
        expect(metric.series.first.value).to be(:==, 5.0)
      end
    end

    describe "gauge series" do
      let(:metric) { snapshot.metrics.find { |m| m.name == :temp } }

      it "has correct shape" do
        expect(metric.type).to be(:==, :gauge)
        expect(metric.series.length).to be(:==, 1)
        expect(metric.series.first.labels).to be(:==, { sensor: "cpu" })
        expect(metric.series.first.value).to be(:==, 22.5)
      end
    end

    describe "histogram series" do
      let(:metric) { snapshot.metrics.find { |m| m.name == :dur } }

      it "has HistogramValue with correct fields" do
        expect(metric.type).to be(:==, :histogram)
        series = metric.series.first
        expect(series.value).to be_a(FastPrometheusClient::HistogramValue)
        expect(series.value.sum).to be(:==, 2.0)
        expect(series.value.count).to be(:==, 2)
        expect(series.value.cumulative_buckets.last.first).to be(:==, Float::INFINITY)
        expect(series.value.cumulative_buckets.last.last).to be(:==, 2)
      end
    end

    describe "summary series" do
      let(:metric) { snapshot.metrics.find { |m| m.name == :size } }

      it "has SnapshotSummaryValue with correct fields" do
        expect(metric.type).to be(:==, :summary)
        series = metric.series.first
        expect(series.value).to be_a(FastPrometheusClient::SnapshotSummaryValue)
        expect(series.value.sum).to be(:==, 300.0)
        expect(series.value.count).to be(:==, 2)
      end
    end

    describe "native histogram series" do
      let(:metric) { snapshot.metrics.find { |m| m.name == :ndur } }

      it "has NativeHistogramValue with correct fields" do
        expect(metric.type).to be(:==, :native_histogram)
        series = metric.series.first
        expect(series.value).to be_a(FastPrometheusClient::NativeHistogramValue)
        expect(series.value.sum).to be(:==, -1.0)
        expect(series.value.count).to be(:==, 2)
        expect(series.value.schema).to be(:==, 3)
      end
    end

    describe "immutability" do
      it "snapshot is unchanged after mutating live metrics" do
        snap = registry.collect

        counter.increment(by: 100)
        gauge.set(99.9, labels: { sensor: "cpu" })
        histogram.observe(999)
        summary.observe(9999)
        native_histogram.observe(9999)

        expect(snap.metrics.find { |m| m.name == :req_total }.series.first.value)
          .to be(:==, 5.0)
        expect(snap.metrics.find { |m| m.name == :temp }.series.first.value)
          .to be(:==, 22.5)
        expect(snap.metrics.find { |m| m.name == :dur }.series.first.value.count)
          .to be(:==, 2)
        expect(snap.metrics.find { |m| m.name == :size }.series.first.value.count)
          .to be(:==, 2)
        expect(snap.metrics.find { |m| m.name == :ndur }.series.first.value.count)
          .to be(:==, 2)
      end

      it "nested arrays are frozen" do
        dur = snapshot.metrics.find { |m| m.name == :dur }
        expect(dur.series.first.value.cumulative_buckets.frozen?).to be(:==, true)

        ndur = snapshot.metrics.find { |m| m.name == :ndur }
        expect(ndur.series.first.value.positive_buckets.frozen?).to be(:==, true)
        expect(ndur.series.first.value.negative_buckets.frozen?).to be(:==, true)
      end
    end
  end
end
