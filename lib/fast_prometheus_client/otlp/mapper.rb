# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("pb", __dir__)) unless $LOAD_PATH.include?(File.expand_path("pb", __dir__))

require "opentelemetry/proto/collector/metrics/v1/metrics_service_pb"

module FastPrometheusClient
  module OTLP
    # Maps a Snapshot to an ExportMetricsServiceRequest.
    class Mapper
      CUMULATIVE = Opentelemetry::Proto::Metrics::V1::AggregationTemporality::AGGREGATION_TEMPORALITY_CUMULATIVE
      private_constant :CUMULATIVE

      def initialize(resource_attributes: {}, start_time: Time.now)
        @resource_attributes = resource_attributes
        @start_time_unix_nano = (start_time.to_f * 1_000_000_000).to_i
      end

      def request(snapshot)
        Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest.new(
          resource_metrics: [
            Opentelemetry::Proto::Metrics::V1::ResourceMetrics.new(
              resource: Opentelemetry::Proto::Resource::V1::Resource.new(
                attributes: @resource_attributes.map { |k, v| kv(k, v) }
              ),
              scope_metrics: [
                Opentelemetry::Proto::Metrics::V1::ScopeMetrics.new(
                  scope: Opentelemetry::Proto::Common::V1::InstrumentationScope.new(
                    name: "fast-prometheus-client",
                    version: FastPrometheusClient::VERSION
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

        Opentelemetry::Proto::Metrics::V1::Metric.new(
          name: metric_snapshot.name.to_s,
          description: metric_snapshot.docstring,
          **build_data(metric_snapshot, time_unix_nano)
        )
      end

      def build_data(metric_snapshot, time_unix_nano)
        case metric_snapshot.type
        when :counter
          {
            sum: Opentelemetry::Proto::Metrics::V1::Sum.new(
              data_points: metric_snapshot.series.map do |series|
                number_data_point(series, time_unix_nano)
              end,
              aggregation_temporality: CUMULATIVE,
              is_monotonic: true
            )
          }
        when :gauge
          {
            gauge: Opentelemetry::Proto::Metrics::V1::Gauge.new(
              data_points: metric_snapshot.series.map do |series|
                number_data_point(series, time_unix_nano)
              end
            )
          }
        when :histogram
          {
            histogram: Opentelemetry::Proto::Metrics::V1::Histogram.new(
              data_points: metric_snapshot.series.map do |series|
                histogram_data_point(series, time_unix_nano)
              end,
              aggregation_temporality: CUMULATIVE
            )
          }
        when :summary
          {
            summary: Opentelemetry::Proto::Metrics::V1::Summary.new(
              data_points: metric_snapshot.series.map do |series|
                summary_data_point(series, time_unix_nano)
              end
            )
          }
        when :native_histogram
          {
            exponential_histogram: Opentelemetry::Proto::Metrics::V1::ExponentialHistogram.new(
              data_points: metric_snapshot.series.map do |series|
                exponential_histogram_data_point(series, time_unix_nano)
              end,
              aggregation_temporality: CUMULATIVE
            )
          }
        end
      end

      def number_data_point(series, time_unix_nano)
        Opentelemetry::Proto::Metrics::V1::NumberDataPoint.new(
          attributes: build_attributes(series.labels),
          start_time_unix_nano: @start_time_unix_nano,
          time_unix_nano: time_unix_nano,
          as_double: series.value.to_f
        )
      end

      def histogram_data_point(series, time_unix_nano)
        nv = series.value
        bounds, counts = non_cumulative_buckets(nv.cumulative_buckets)

        Opentelemetry::Proto::Metrics::V1::HistogramDataPoint.new(
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
        counts = []
        prev = 0

        cumulative_buckets.each do |boundary, cumulative|
          counts << cumulative - prev
          prev = cumulative
          bounds << boundary unless boundary.infinite?
        end

        [bounds, counts]
      end

      def summary_data_point(series, time_unix_nano)
        sv = series.value

        Opentelemetry::Proto::Metrics::V1::SummaryDataPoint.new(
          attributes: build_attributes(series.labels),
          start_time_unix_nano: @start_time_unix_nano,
          time_unix_nano: time_unix_nano,
          count: sv.count,
          sum: sv.sum
        )
      end

      def exponential_histogram_data_point(series, time_unix_nano)
        nv = series.value

        Opentelemetry::Proto::Metrics::V1::ExponentialHistogramDataPoint.new(
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
      def dense_buckets(buckets)
        return Opentelemetry::Proto::Metrics::V1::ExponentialHistogramDataPoint::Buckets.new if buckets.empty?

        otlp_indices = buckets.map { |idx, _| idx - 1 }
        offset = otlp_indices.min
        length = otlp_indices.max - offset + 1

        counts = Array.new(length, 0)
        buckets.each do |prom_idx, count|
          counts[prom_idx - 1 - offset] = count
        end

        Opentelemetry::Proto::Metrics::V1::ExponentialHistogramDataPoint::Buckets.new(
          offset: offset,
          bucket_counts: counts
        )
      end

      def build_attributes(labels)
        labels.map { |k, v| kv(k.to_s, v.to_s) }
      end

      def kv(key, value)
        Opentelemetry::Proto::Common::V1::KeyValue.new(
          key: key,
          value: Opentelemetry::Proto::Common::V1::AnyValue.new(string_value: value)
        )
      end
    end
  end
end
