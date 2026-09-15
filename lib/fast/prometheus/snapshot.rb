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
      # and copies all mutable structures. The whole build runs under the
      # metric's lock so no series is observed mid-mutation and no writer
      # interleaves between series.
      def self.of(metric)
        metric.synchronize do
          new(
            metric.name,
            metric.docstring,
            metric.type,
            metric.labels.dup.freeze,
            build_series(metric).freeze
          )
        end
      end

      def self.build_series(metric)
        metric.snapshot_values.map do |labels, value|
          Series.new(labels: labels.dup.freeze, value: value)
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
