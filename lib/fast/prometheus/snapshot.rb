# frozen_string_literal: true

module Fast
  module Prometheus
    # Immutable value types for snapshots.
    #
    # The per-series types are Structs frozen where they are built, not
    # Data: Data.new allocates two objects besides the instance, and a
    # scrape builds one of these per series. The per-registry types are Data.
    # (sum and count shadow Enumerable's on the Structs, as they would on Data.)

    HistogramValue = Struct.new(:sum, :count, :cumulative_buckets) # rubocop:disable Lint/StructNewOverride

    NativeHistogramValue = Struct.new(:schema, :zero_threshold, :zero_count, :sum, :count, # rubocop:disable Lint/StructNewOverride
                                      :positive_buckets, :negative_buckets)

    Series = Struct.new(:labels, :value)

    SummaryValue = Struct.new(:sum, :count) # rubocop:disable Lint/StructNewOverride

    MetricSnapshot = Data.define(:name, :docstring, :type, :label_names, :series) do
      # Build a MetricSnapshot from a live metric. Reads only public readers;
      # #snapshot_values hands over fresh frozen label hashes and frozen
      # values, so nothing here is copied again. The whole build runs under
      # the metric's lock so no series is observed mid-mutation and no writer
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

      # each_pair, not map: a two-parameter block gets key and value
      # directly, where map would build a pair Array per series.
      def self.build_series(metric)
        series = []
        metric.snapshot_values.each_pair { |labels, value| series << Series.new(labels, value).freeze }
        series
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
