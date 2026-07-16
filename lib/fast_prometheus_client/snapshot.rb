# frozen_string_literal: true

module FastPrometheusClient
  # Immutable value types for snapshots. Deep-frozen Data types.

  HistogramValue = Data.define(:sum, :count, :cumulative_buckets)

  NativeHistogramValue = Data.define(:schema, :zero_threshold, :zero_count, :sum, :count,
                                     :positive_buckets, :negative_buckets)

  Series = Data.define(:labels, :value)

  # DISAGREEMENT: FastPrometheusClient::SummaryValue is already defined in
  # summary.rb as a mutable storage class (no-arg initialize). Defining a
  # Data type with the same name here would overwrite it and break the
  # Summary metric. Using SnapshotSummaryValue as a workaround.
  SnapshotSummaryValue = Data.define(:sum, :count)

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
      case metric.type
      when :counter, :gauge
        metric.values.map do |labels, value|
          Series.new(labels: labels.dup.freeze, value: value)
        end
      when :histogram
        metric.values.map do |labels, slot|
          Series.new(
            labels: labels.dup.freeze,
            value: HistogramValue.new(
              sum: slot.sum,
              count: slot.count,
              cumulative_buckets: slot.cumulative_buckets.map(&:dup).freeze
            )
          )
        end
      when :summary
        metric.values.map do |labels, value|
          Series.new(
            labels: labels.dup.freeze,
            value: SnapshotSummaryValue.new(sum: value.sum, count: value.count)
          )
        end
      when :native_histogram
        metric.values.map do |labels, slot|
          Series.new(
            labels: labels.dup.freeze,
            value: NativeHistogramValue.new(
              schema: slot.schema,
              zero_threshold: slot.zero_threshold,
              zero_count: slot.zero_count,
              sum: slot.sum,
              count: slot.count,
              positive_buckets: slot.positive_buckets.map(&:dup).freeze,
              negative_buckets: slot.negative_buckets.map(&:dup).freeze
            )
          )
        end
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
