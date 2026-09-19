# frozen_string_literal: true

require_relative "metric"

module Fast
  module Prometheus
    # Native (sparse exponential) histogram.
    #
    # Covers the full float range with sparse base-2 exponential buckets.
    # Bucket layout matches the Prometheus native histogram model exactly.
    class NativeHistogram < Metric
      # Inner value object holding one label series' histogram data.
      # Per-series because downscaling is independent per series.
      class Slot
        attr_reader :zero_threshold
        attr_accessor :schema, :sum, :count, :zero_count, :positive, :negative

        def initialize(schema:, zero_threshold:)
          @schema = schema
          @zero_threshold = zero_threshold
          @sum = 0.0
          @count = 0
          @zero_count = 0
          @positive = {}
          @negative = {}
        end

        # Sorted frozen [index, count] pairs for the positive side.
        def positive_buckets
          @positive.sort.each(&:freeze).freeze
        end

        # Sorted frozen [index, count] pairs for the negative side.
        def negative_buckets
          @negative.sort.each(&:freeze).freeze
        end
      end

      # client_golang math.MaxInt32 convention for clamped ±Inf bucket index.
      MAX_BUCKET_INDEX = (2**31) - 1

      attr_reader :schema, :zero_threshold, :max_buckets

      def initialize(name, docstring:, labels: [], preset_labels: {}, schema: 3, zero_threshold: 2.0**-128,
                     max_buckets: 160, store: nil)
        valid_schema = schema.is_a?(Integer) && (-4..8).include?(schema)
        raise ArgumentError, "schema must be an Integer in -4..8" unless valid_schema

        valid_zero_threshold = zero_threshold.is_a?(Float) && zero_threshold >= 0
        raise ArgumentError, "zero_threshold must be a Float >= 0" unless valid_zero_threshold

        valid_max_buckets = max_buckets.is_a?(Integer) && max_buckets.positive?
        raise ArgumentError, "max_buckets must be an Integer > 0" unless valid_max_buckets

        @schema = schema
        @zero_threshold = zero_threshold
        @max_buckets = max_buckets

        super(name, docstring: docstring, labels: labels, preset_labels: preset_labels, store: store)
      end

      def type
        :native_histogram
      end

      # Record an observation. A non-Numeric is an ArgumentError, as it is on
      # every other type; NaN and ±Inf are handled gracefully and never raise.
      def observe(value, labels: NO_LABELS)
        raise ArgumentError, "value must be a numeric" unless value.is_a?(Numeric)

        v = value.to_f
        key = resolve(labels)

        store.synchronize do
          slot = store[key] ||= Slot.new(schema: @schema, zero_threshold: @zero_threshold)

          # Determine bucket placement BEFORE mutating count/sum (no partial mutation).
          if v.nan?
            # NaN: count/sum only, no bucket.
            side = nil
            idx = nil
          elsif v.infinite?
            # ±Inf: clamp to MAX_BUCKET_INDEX.
            side = v.positive? ? :positive : :negative
            idx = MAX_BUCKET_INDEX
          elsif v.abs <= slot.zero_threshold
            side = :zero
            idx = nil
          elsif v.positive?
            side = :positive
            idx = index_for(v, slot.schema)
          else
            side = :negative
            idx = index_for(-v, slot.schema)
          end

          slot.sum += v
          slot.count += 1

          case side
          when :zero
            slot.zero_count += 1
          when :positive
            slot.positive[idx] = (slot.positive[idx] || 0) + 1
          when :negative
            slot.negative[idx] = (slot.negative[idx] || 0) + 1
          end

          downscale(slot) while slot.positive.size + slot.negative.size > @max_buckets && slot.schema > -4
        end
      end

      # A frozen NativeHistogramValue for a label set; zero-valued at this
      # metric's schema/zero_threshold for an unobserved series.
      def get(labels: NO_LABELS)
        key = resolve(labels)
        store.synchronize { snapshot_value(store[key] || zero_value) }
      end

      def values
        series_map { |slot| snapshot_value(slot) }
      end

      protected

      def construction_options
        { schema: @schema, zero_threshold: @zero_threshold, max_buckets: @max_buckets }
      end

      private

      def zero_value
        Slot.new(schema: @schema, zero_threshold: @zero_threshold)
      end

      def snapshot_value(slot)
        NativeHistogramValue.new(slot.schema, slot.zero_threshold, slot.zero_count, slot.sum, slot.count,
                                 slot.positive_buckets, slot.negative_buckets).freeze
      end

      def index_for(value, schema)
        factor = 2.0**schema
        idx = (Math.log2(value) * factor).ceil
        idx -= 1 while 2.0**((idx - 1) / factor) >= value
        idx += 1 while 2.0**(idx / factor) < value
        idx
      end

      def downscale(slot)
        delta = 1
        shift = 1 << delta
        slot.positive = slot.positive.each_with_object({}) do |(idx, count), hash|
          hash[-(-idx / shift)] = (hash[-(-idx / shift)] || 0) + count
        end
        slot.negative = slot.negative.each_with_object({}) do |(idx, count), hash|
          hash[-(-idx / shift)] = (hash[-(-idx / shift)] || 0) + count
        end
        slot.schema -= delta
      end
    end
  end
end
