# frozen_string_literal: true

require "fast/prometheus"
require_relative "proto"

module Fast
  module Prometheus
    module OTLP
      # Maps a Snapshot to a Proto::ExportMetricsServiceRequest.
      class Mapper
        CUMULATIVE = :AGGREGATION_TEMPORALITY_CUMULATIVE
        private_constant :CUMULATIVE

        def initialize(resource_attributes: {}, start_time: Time.now)
          @resource_attributes = resource_attributes.map { |k, v| kv(k, v) }
          @start_time_unix_nano = (start_time.to_f * 1_000_000_000).to_i
        end

        def request(snapshot)
          Proto::ExportMetricsServiceRequest.new(
            resource_metrics: [
              Proto::ResourceMetrics.new(
                resource: Proto::Resource.new(
                  attributes: @resource_attributes
                ),
                scope_metrics: [
                  Proto::ScopeMetrics.new(
                    scope: Proto::InstrumentationScope.new(
                      name: "fast-prometheus",
                      version: Fast::Prometheus::VERSION
                    ),
                    metrics: snapshot.metrics.map { |ms| build_metric(ms, snapshot.taken_at) }
                  )
                ]
              )
            ]
          )
        end

        private

        def build_metric(metric_snapshot, taken_at)
          time_unix_nano = (taken_at.to_f * 1_000_000_000).to_i

          Proto::Metric.new(
            name: metric_snapshot.name.to_s,
            description: metric_snapshot.docstring,
            **build_data(metric_snapshot, time_unix_nano)
          )
        end

        def build_data(metric_snapshot, time_unix_nano)
          case metric_snapshot.type
          when :counter
            {
              sum: Proto::Sum.new(
                data_points: metric_snapshot.series.map do |series|
                  number_data_point(series, time_unix_nano)
                end,
                aggregation_temporality: CUMULATIVE,
                is_monotonic: true
              )
            }
          when :gauge
            {
              gauge: Proto::Gauge.new(
                data_points: metric_snapshot.series.map do |series|
                  number_data_point(series, time_unix_nano)
                end
              )
            }
          when :histogram
            {
              histogram: Proto::Histogram.new(
                data_points: metric_snapshot.series.map do |series|
                  histogram_data_point(series, time_unix_nano)
                end,
                aggregation_temporality: CUMULATIVE
              )
            }
          when :summary
            {
              summary: Proto::Summary.new(
                data_points: metric_snapshot.series.map do |series|
                  summary_data_point(series, time_unix_nano)
                end
              )
            }
          when :native_histogram
            {
              exponential_histogram: Proto::ExponentialHistogram.new(
                data_points: metric_snapshot.series.map do |series|
                  exponential_histogram_data_point(series, time_unix_nano)
                end,
                aggregation_temporality: CUMULATIVE
              )
            }
          end
        end

        def number_data_point(series, time_unix_nano)
          Proto::NumberDataPoint.new(
            attributes: build_attributes(series.labels),
            start_time_unix_nano: @start_time_unix_nano,
            time_unix_nano: time_unix_nano,
            as_double: series.value.to_f
          )
        end

        def histogram_data_point(series, time_unix_nano)
          nv = series.value
          bounds, counts = non_cumulative_buckets(nv.cumulative_buckets)

          Proto::HistogramDataPoint.new(
            attributes: build_attributes(series.labels),
            start_time_unix_nano: @start_time_unix_nano,
            time_unix_nano: time_unix_nano,
            count: nv.count,
            sum: nv.sum,
            bucket_counts: counts,
            explicit_bounds: bounds
          )
        end

        def non_cumulative_buckets(cumulative_buckets)
          # cumulative_buckets: [[bound1, cum1], [bound2, cum2], ..., [+Inf, cumN]]
          # bounds = all boundaries except +Inf
          # counts = non-cumulative per-bucket counts + overflow
          bounds = []
          counts = Array.new(cumulative_buckets.size)
          prev = 0

          cumulative_buckets.each_with_index do |(boundary, cumulative), i|
            counts[i] = cumulative - prev
            prev = cumulative
            bounds << boundary unless boundary.infinite?
          end

          [bounds, counts]
        end

        def summary_data_point(series, time_unix_nano)
          sv = series.value

          Proto::SummaryDataPoint.new(
            attributes: build_attributes(series.labels),
            start_time_unix_nano: @start_time_unix_nano,
            time_unix_nano: time_unix_nano,
            count: sv.count,
            sum: sv.sum
          )
        end

        def exponential_histogram_data_point(series, time_unix_nano)
          nv = series.value

          Proto::ExponentialHistogramDataPoint.new(
            attributes: build_attributes(series.labels),
            start_time_unix_nano: @start_time_unix_nano,
            time_unix_nano: time_unix_nano,
            count: nv.count,
            sum: nv.sum,
            scale: nv.schema,
            zero_count: nv.zero_count,
            zero_threshold: nv.zero_threshold,
            positive: dense_buckets(nv.positive_buckets),
            negative: dense_buckets(nv.negative_buckets)
          )
        end

        # Convert sparse [[prom_idx, count], ...] to OTLP Buckets{offset, bucket_counts}.
        # OTLP index = prom index - 1. Offset = min OTLP index.
        # Buckets are always sorted (from NativeHistogram::Slot#positive_buckets / #negative_buckets).
        def dense_buckets(buckets)
          return Proto::ExponentialHistogramDataPoint::Buckets.new if buckets.empty?

          first_idx, = buckets.first
          last_idx, = buckets.last
          offset = first_idx - 1
          length = last_idx - offset

          counts = Array.new(length, 0)
          buckets.each { |prom_idx, count| counts[prom_idx - offset - 1] = count }

          Proto::ExponentialHistogramDataPoint::Buckets.new(
            offset: offset,
            bucket_counts: counts
          )
        end

        def build_attributes(labels)
          labels.map { |k, v| kv(k.to_s, v.to_s) }
        end

        def kv(key, value)
          Proto::KeyValue.new(
            key: key,
            value: Proto::AnyValue.new(string_value: value)
          )
        end
      end
    end
  end
end
