# frozen_string_literal: true

module Fast
  module Prometheus
    # Immutable value types for snapshots. Deep-frozen Data types.

    HistogramValue = Data.define(:sum, :count, :cumulative_buckets)

    NativeHistogramValue = Data.define(:schema, :zero_threshold, :zero_count, :sum, :count,
                                       :positive_buckets, :negative_buckets)

    Series = Data.define(:labels, :value)

    SummaryValue = Data.define(:sum, :count)

    MetricSnapshot = Data.define(:name, :docstring, :type, :label_names, :series) do
      # Build a MetricSnapshot from a live metric. Reads only public readers
      # and copies all mutable structures.
      def self.of(metric)
        new(
          metric.name,
          metric.docstring,
          metric.type,
          metric.label_names.dup.freeze,
          build_series(metric).freeze
        )
      end

      def self.build_series(metric)
        metric.values.map do |labels, value|
          Series.new(
            labels: labels.dup.freeze,
            value: build_value(metric.type, value)
          )
        end
      end

      private_class_method def self.build_value(type, value)
        case type
        when :counter, :gauge
          value
        when :histogram
          HistogramValue.new(
            sum: value.sum,
            count: value.count,
            cumulative_buckets: value.cumulative_buckets.map { |pair| pair.dup.freeze }.freeze
          )
        when :summary
          SummaryValue.new(sum: value.sum, count: value.count)
        when :native_histogram
          NativeHistogramValue.new(
            schema: value.schema,
            zero_threshold: value.zero_threshold,
            zero_count: value.zero_count,
            sum: value.sum,
            count: value.count,
            positive_buckets: value.positive_buckets.map { |pair| pair.dup.freeze }.freeze,
            negative_buckets: value.negative_buckets.map { |pair| pair.dup.freeze }.freeze
          )
        end
      end
    end

    Snapshot = Data.define(:metrics, :taken_at) do
      # Build a Snapshot from an array of live metrics.
      def self.of(metrics)
        new(
          metrics.map { |metric| MetricSnapshot.of(metric) }.freeze,
          Time.now
        )
      end
    end
  end
end
