# frozen_string_literal: true

module Fast
  module Prometheus
    # Immutable value types for snapshots.
    #
    # A MetricSnapshot's +series+ is the metric's store as it stood at one
    # instant: a frozen Hash from each series' label values (an Array in
    # +label_names+ order, the store's own key) to its value. Counter and
    # gauge values are Floats; the other types' values are the frozen
    # Structs below, built from the live slot while the store was locked.
    # Nothing per series is copied beyond that, so a snapshot of any size
    # costs one Hash per metric.
    #
    # The value shapes are Structs frozen where they are built, not Data:
    # Data.new allocates two objects besides the instance, and a scrape
    # builds one of these per histogram, summary or native histogram series.
    # (sum and count shadow Enumerable's on the Structs, as they would on Data.)

    HistogramValue = Struct.new(:sum, :count, :cumulative_buckets) # rubocop:disable Lint/StructNewOverride

    NativeHistogramValue = Struct.new(:schema, :zero_threshold, :zero_count, :sum, :count, # rubocop:disable Lint/StructNewOverride
                                      :positive_buckets, :negative_buckets)

    SummaryValue = Struct.new(:sum, :count) # rubocop:disable Lint/StructNewOverride

    MetricSnapshot = Data.define(:name, :docstring, :type, :label_names, :series) do
      # Build a MetricSnapshot from a live metric. +series+ is the metric's
      # store copied and its slots frozen under the metric's lock (see
      # Metric#snapshot_values), so no series is observed mid-mutation and
      # no writer interleaves between series.
      def self.of(metric)
        new(metric.name, metric.docstring, metric.type, metric.labels.dup.freeze, metric.snapshot_values.freeze)
      end

      # The {name => value} Hash for one series' label values.
      def labels(values)
        label_names.zip(values).to_h
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
