# frozen_string_literal: true

require "fast/prometheus"
require "sus/fixtures/async"

describe Fast::Prometheus::NativeHistogram do
  describe ".new" do
    it "has type :native_histogram" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      expect(nh.type).to be(:==, :native_histogram)
    end

    it "raises on schema 9" do
      expect do
        Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 9)
      end.to raise_exception(ArgumentError)
    end

    it "raises on schema -5" do
      expect do
        Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: -5)
      end.to raise_exception(ArgumentError)
    end
  end

  describe "index_for" do
    it "anchors: schema 0, 4.0 -> 2" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 0)
      nh.observe(4.0)
      slot = nh.get
      expect(slot.positive_buckets).to be(:==, [[2, 1]])
    end

    it "anchors: schema 0, 5.0 -> 3" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 0)
      nh.observe(5.0)
      slot = nh.get
      expect(slot.positive_buckets).to be(:==, [[3, 1]])
    end

    it "anchors: schema 0, 1.0 -> 0" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 0)
      nh.observe(1.0)
      slot = nh.get
      expect(slot.positive_buckets).to be(:==, [[0, 1]])
    end

    it "anchors: schema 3, 1.0 -> 0" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 3)
      nh.observe(1.0)
      slot = nh.get
      expect(slot.positive_buckets).to be(:==, [[0, 1]])
    end

    it "anchors: schema 3, 1.1 -> 2" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 3)
      nh.observe(1.1)
      slot = nh.get
      expect(slot.positive_buckets).to be(:==, [[2, 1]])
    end

    it "anchors: schema 0, the smallest subnormal (2**-1074) -> -1074" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 0, zero_threshold: 0.0)
      nh.observe(5e-324)
      slot = nh.get
      expect(slot.positive_buckets).to be(:==, [[-1074, 1]])
    end

    it "anchors: schema 3, 2**-1073 -> -8584" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 3, zero_threshold: 0.0)
      nh.observe(1e-323)
      slot = nh.get
      expect(slot.positive_buckets).to be(:==, [[-8584, 1]])
    end

    it "exact power of base lands in bucket where it is the upper bound" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 0)
      nh.observe(2.0)
      slot = nh.get
      expect(slot.positive_buckets).to be(:==, [[1, 1]])
    end
  end

  describe "#observe" do
    it "zero bucket: 0.0 and 1e-300 -> zero_count 2, no positive" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(0.0)
      nh.observe(1e-300)
      slot = nh.get
      expect(slot.zero_count).to be(:==, 2)
      expect(slot.positive_buckets).to be(:==, [])
    end

    it "negatives mirror into negative_buckets" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", schema: 0)
      nh.observe(-4.0)
      slot = nh.get
      expect(slot.negative_buckets).to be(:==, [[2, 1]])
    end

    it "count includes zero-bucket observations" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(0.0)
      nh.observe(1.0)
      slot = nh.get
      expect(slot.count).to be(:==, 2)
    end

    it "sum accumulates" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(1.5)
      nh.observe(2.5)
      slot = nh.get
      expect(slot.sum).to be(:==, 4.0)
    end

    it "NaN: count and sum updated, no bucket, no zero_count" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(Float::NAN)
      slot = nh.get
      expect(slot.count).to be(:==, 1)
      expect(slot.sum.nan?).to be(:==, true)
      expect(slot.zero_count).to be(:==, 0)
      expect(slot.positive_buckets).to be(:==, [])
      expect(slot.negative_buckets).to be(:==, [])
    end

    it "+Inf: count/sum updated, positive bucket at MAX_BUCKET_INDEX" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(Float::INFINITY)
      slot = nh.get
      expect(slot.count).to be(:==, 1)
      expect(slot.sum).to be(:==, Float::INFINITY)
      expect(slot.positive_buckets).to be(:==, [[Fast::Prometheus::NativeHistogram::MAX_BUCKET_INDEX, 1]])
      expect(slot.negative_buckets).to be(:==, [])
    end

    it "-Inf: count/sum updated, negative bucket at MAX_BUCKET_INDEX" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(-Float::INFINITY)
      slot = nh.get
      expect(slot.count).to be(:==, 1)
      expect(slot.sum).to be(:==, -Float::INFINITY)
      expect(slot.positive_buckets).to be(:==, [])
      expect(slot.negative_buckets).to be(:==, [[Fast::Prometheus::NativeHistogram::MAX_BUCKET_INDEX, 1]])
    end

    it "raises on a non-Numeric value" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      [nil, "1.5", :sym, [1]].each do |bad|
        expect { nh.observe(bad) }.to raise_exception(ArgumentError)
      end
    end

    it "observes any Numeric" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(1)
      nh.observe(2.5r)
      expect(nh.get.count).to be(:==, 2)
    end

    it "NaN/±Inf never raise" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      expect { nh.observe(Float::NAN) }.not.to raise_exception
      expect { nh.observe(Float::INFINITY) }.not.to raise_exception
      expect { nh.observe(-Float::INFINITY) }.not.to raise_exception
    end

    it "finite values after NaN still work" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(Float::NAN)
      nh.observe(1.0)
      slot = nh.get
      expect(slot.count).to be(:==, 2)
      expect(slot.sum.nan?).to be(:==, true)
      expect(slot.positive_buckets).to be(:==, [[0, 1]])
    end
  end

  describe "downscale" do
    it "respects max_buckets" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", max_buckets: 4)
      [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0].each { |v| nh.observe(v) }
      slot = nh.get
      expect(slot.positive_buckets.length).to be(:<=, 4)
      expect(slot.schema).to be(:<, 3)
      expect(slot.count).to be(:==, 7)
      expect(slot.sum).to be(:==, 127.0)
    end
  end

  describe "#get" do
    it "returns a frozen zero-valued NativeHistogramValue when no observations" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", labels: [:service])
      value = nh.get(labels: { service: "auth" })
      expect(value).to be_a(Fast::Prometheus::NativeHistogramValue)
      expect(value.frozen?).to be(:==, true)
      expect(value.count).to be(:==, 0)
      expect(value.schema).to be(:==, nh.schema)
    end

    it "returns a frozen NativeHistogramValue after observations" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(1.0)
      expect(nh.get.frozen?).to be(:==, true)
    end

    it "returns count/zero_count/positive_buckets after observations" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      nh.observe(1.5)
      nh.observe(0.0)
      value = nh.get
      expect(value.count).to be(:==, 2)
      expect(value.zero_count).to be(:==, 1)
      expect(value.positive_buckets.length).to be(:==, 1)
    end
  end

  describe "#with_labels" do
    it "binds an observe that's visible via the parent, preserving schema" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", labels: [:service], schema: 2)
      bound = nh.with_labels(service: "auth")
      bound.observe(1.5)
      slot = nh.get(labels: { service: "auth" })
      expect(slot.count).to be(:==, 1)
      expect(slot.schema).to be(:==, 2)
    end
  end

  describe "#values" do
    it "keys frozen NativeHistogramValues by label set" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", labels: [:service])
      nh.observe(1.0, labels: { service: "auth" })
      values = nh.values
      expect(values.keys).to be(:==, [{ service: "auth" }])
      expect(values[{ service: "auth" }]).to be_a(Fast::Prometheus::NativeHistogramValue)
    end
  end

  describe "#snapshot_values" do
    it "keys frozen NativeHistogramValues by label set, matching #get and MetricSnapshot.of" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", labels: [:service])
      nh.observe(1.0, labels: { service: "auth" })
      value = nh.snapshot_values[["auth"]]
      expect(value).to be(:==, nh.get(labels: { service: "auth" }))
      expect(value).to be(:==, Fast::Prometheus::MetricSnapshot.of(nh).series.values.first)
    end
  end

  describe "seeding" do
    it "seeds a zero-valued series at construction when fully bound" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")
      expect(nh.values.keys).to be(:==, [{}])
      expect(nh.values[{}].count).to be(:==, 0)
    end

    it "seeds nothing when partially bound" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", labels: [:service])
      expect(nh.values).to be(:==, {})
    end

    it "seeds a fully-bound with_labels child" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", labels: [:service])
      nh.with_labels(service: "auth")
      expect(nh.values.keys).to be(:==, [{ service: "auth" }])
    end
  end

  describe "#init_label_set" do
    it "creates an absent series at zero without resetting a live one" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", labels: [:service])
      nh.observe(1.0, labels: { service: "auth" })
      nh.init_label_set(service: "auth")
      nh.init_label_set(service: "billing")
      expect(nh.get(labels: { service: "auth" }).count).to be(:==, 1)
      expect(nh.get(labels: { service: "billing" }).count).to be(:==, 0)
    end

    it "raises InvalidLabelSet on an unknown label" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t", labels: [:service])
      expect { nh.init_label_set(bogus: "1") }.to raise_exception(Fast::Prometheus::InvalidLabelSet)
    end
  end

  describe "fiber-safety" do
    include Sus::Fixtures::Async::ReactorContext

    it "accumulates correctly under 500 concurrent observes" do
      nh = Fast::Prometheus::NativeHistogram.new(:t, docstring: "t")

      run_with_timeout do
        tasks = 500.times.map do
          Async do
            nh.observe(1.5)
          end
        end

        tasks.each(&:wait)
      end

      slot = nh.get
      expect(slot.count).to be(:==, 500)
      expect(slot.positive_buckets.length).to be(:==, 1)
      expect(slot.positive_buckets.first.last).to be(:==, 500)
    end
  end
end
