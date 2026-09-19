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

        # OTLP carries one contiguous bucket-count array per side, so an export
        # must never size an Array by the distance between two observations:
        # past this many slots a data point drops to a coarser scale instead.
        MAX_DENSE_BUCKETS = 1024
        private_constant :MAX_DENSE_BUCKETS

        def initialize(resource_attributes: {}, start_time: Time.now)
          @resource_attributes = resource_attributes.map { |key, value| kv(key, any_value(value)) }
          @start_time_unix_nano = unix_nano(start_time)
        end

        def request(snapshot)
          time_unix_nano = unix_nano(snapshot.taken_at)

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
                    metrics: snapshot.metrics.map { |ms| build_metric(ms, time_unix_nano) }
                  )
                ]
              )
            ]
          )
        end

        private

        # Exact nanoseconds: at epoch magnitudes a Float loses the low ~256ns.
        def unix_nano(time)
          (time.tv_sec * 1_000_000_000) + time.tv_nsec
        end

        def build_metric(metric_snapshot, time_unix_nano)
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
                data_points: data_points(metric_snapshot) do |attributes, value|
                  number_data_point(attributes, value, time_unix_nano)
                end,
                aggregation_temporality: CUMULATIVE,
                is_monotonic: true
              )
            }
          when :gauge
            {
              gauge: Proto::Gauge.new(
                data_points: data_points(metric_snapshot) do |attributes, value|
                  number_data_point(attributes, value, time_unix_nano)
                end
              )
            }
          when :histogram
            {
              histogram: Proto::Histogram.new(
                data_points: data_points(metric_snapshot) do |attributes, value|
                  histogram_data_point(attributes, value, time_unix_nano)
                end,
                aggregation_temporality: CUMULATIVE
              )
            }
          when :summary
            {
              summary: Proto::Summary.new(
                data_points: data_points(metric_snapshot) do |attributes, value|
                  summary_data_point(attributes, value, time_unix_nano)
                end
              )
            }
          when :native_histogram
            {
              exponential_histogram: Proto::ExponentialHistogram.new(
                data_points: data_points(metric_snapshot) do |attributes, value|
                  exponential_histogram_data_point(attributes, value, time_unix_nano)
                end,
                aggregation_temporality: CUMULATIVE
              )
            }
          end
        end

        # One data point per series: the block gets the series' OTLP
        # attributes and its snapshot value.
        def data_points(metric_snapshot)
          metric_snapshot.series.map { |values, value| yield build_attributes(metric_snapshot.labels(values)), value }
        end

        def number_data_point(attributes, value, time_unix_nano)
          Proto::NumberDataPoint.new(
            attributes: attributes,
            start_time_unix_nano: @start_time_unix_nano,
            time_unix_nano: time_unix_nano,
            as_double: value.to_f
          )
        end

        def histogram_data_point(attributes, value, time_unix_nano)
          bounds, counts = non_cumulative_buckets(value.cumulative_buckets)

          Proto::HistogramDataPoint.new(
            attributes: attributes,
            start_time_unix_nano: @start_time_unix_nano,
            time_unix_nano: time_unix_nano,
            count: value.count,
            sum: value.sum,
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

        def summary_data_point(attributes, value, time_unix_nano)
          Proto::SummaryDataPoint.new(
            attributes: attributes,
            start_time_unix_nano: @start_time_unix_nano,
            time_unix_nano: time_unix_nano,
            count: value.count,
            sum: value.sum
          )
        end

        # A data point carries only the series' finite observations: OTLP has no
        # bucket for an infinity and no count for a NaN, so both are dropped —
        # from the buckets, from +count+, and from +sum+, which is left absent
        # when the series' accumulated sum is no longer finite.
        def exponential_histogram_data_point(attributes, value, time_unix_nano)
          positive = finite_buckets(value.positive_buckets, value.schema)
          negative = finite_buckets(value.negative_buckets, value.schema)
          reduction = scale_reduction(positive, negative)
          positive = merge_buckets(positive, reduction)
          negative = merge_buckets(negative, reduction)

          Proto::ExponentialHistogramDataPoint.new(
            attributes: attributes,
            start_time_unix_nano: @start_time_unix_nano,
            time_unix_nano: time_unix_nano,
            count: value.zero_count + bucket_total(positive) + bucket_total(negative),
            sum: (value.sum if value.sum.finite?),
            scale: value.schema - reduction,
            zero_count: value.zero_count,
            zero_threshold: value.zero_threshold,
            positive: dense_buckets(positive),
            negative: dense_buckets(negative)
          )
        end

        # NativeHistogram clamps a ±Inf observation to MAX_BUCKET_INDEX, and
        # downscaling halves that index along with every other one. Either way
        # it stays above the index of any finite observation, which |value| <=
        # Float::MAX puts at 1024 * 2**schema at the most, so it sorts last and
        # is the only pair up there.
        def finite_buckets(buckets, schema)
          return buckets if buckets.empty? || buckets.last.first <= 1024 * (2.0**schema)

          buckets[0..-2]
        end

        def bucket_total(buckets)
          buckets.sum { |_, count| count }
        end

        # How many times both sides' resolution has to halve for each dense
        # array to fit MAX_DENSE_BUCKETS. A data point carries one scale, so the
        # two sides reduce together.
        def scale_reduction(positive, negative)
          reduction = 0
          reduction += 1 while dense_length(positive, reduction) > MAX_DENSE_BUCKETS ||
                               dense_length(negative, reduction) > MAX_DENSE_BUCKETS
          reduction
        end

        def dense_length(buckets, reduction)
          return 0 if buckets.empty?

          coarse_index(buckets.last.first, reduction) - coarse_index(buckets.first.first, reduction) + 1
        end

        # Merge each run of 2**reduction adjacent buckets into one, as
        # NativeHistogram#downscale does for the schema it reports.
        def merge_buckets(buckets, reduction)
          return buckets if reduction.zero?

          buckets.each_with_object({}) do |(index, count), merged|
            key = coarse_index(index, reduction)
            merged[key] = (merged[key] || 0) + count
          end.to_a
        end

        # The bucket +index+ falls into after halving resolution +reduction+
        # times: rounded toward the wider bucket, as downscaling rounds.
        def coarse_index(index, reduction)
          -(-index / (1 << reduction))
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
          labels.map { |name, value| kv(name, Proto::AnyValue.new(string_value: value.to_s)) }
        end

        def kv(key, any_value)
          Proto::KeyValue.new(key: key.to_s, value: any_value)
        end

        # A resource attribute keeps its Ruby type where OTLP has a member for
        # it; anything else goes over as its +to_s+.
        def any_value(value)
          case value
          when String then Proto::AnyValue.new(string_value: value)
          when Integer then Proto::AnyValue.new(int_value: value)
          when Float then Proto::AnyValue.new(double_value: value)
          when true, false then Proto::AnyValue.new(bool_value: value)
          else Proto::AnyValue.new(string_value: value.to_s)
          end
        end
      end
    end
  end
end
