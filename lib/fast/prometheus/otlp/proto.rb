# frozen_string_literal: true

require "fast/protowire"

module Fast
  module Prometheus
    module OTLP
      # The OTLP metrics data model (proto/opentelemetry, proto3), declared
      # for the wire: what the exporters send and the one response they read.
      module Proto
        class AnyValue < Fast::Protowire::Message
          oneof :value do
            field :string_value, :string, 1
            field :bool_value, :bool, 2
            field :int_value, :int64, 3
            field :double_value, :double, 4
            field :bytes_value, :bytes, 7
          end
        end

        class KeyValue < Fast::Protowire::Message
          field :key, :string, 1
          field :value, AnyValue, 2
        end

        class InstrumentationScope < Fast::Protowire::Message
          field :name, :string, 1
          field :version, :string, 2
          repeated :attributes, KeyValue, 3
          field :dropped_attributes_count, :uint32, 4
        end

        class Resource < Fast::Protowire::Message
          repeated :attributes, KeyValue, 1
          field :dropped_attributes_count, :uint32, 2
        end

        AggregationTemporality = Fast::Protowire::Enum.define(
          AGGREGATION_TEMPORALITY_UNSPECIFIED: 0,
          AGGREGATION_TEMPORALITY_DELTA: 1,
          AGGREGATION_TEMPORALITY_CUMULATIVE: 2
        )

        class NumberDataPoint < Fast::Protowire::Message
          field :start_time_unix_nano, :fixed64, 2
          field :time_unix_nano, :fixed64, 3
          oneof :value do
            field :as_double, :double, 4
            field :as_int, :sfixed64, 6
          end
          repeated :attributes, KeyValue, 7
          field :flags, :uint32, 8
        end

        class HistogramDataPoint < Fast::Protowire::Message
          field :start_time_unix_nano, :fixed64, 2
          field :time_unix_nano, :fixed64, 3
          field :count, :fixed64, 4
          optional :sum, :double, 5
          repeated :bucket_counts, :fixed64, 6
          repeated :explicit_bounds, :double, 7
          repeated :attributes, KeyValue, 9
          field :flags, :uint32, 10
          optional :min, :double, 11
          optional :max, :double, 12
        end

        class SummaryDataPoint < Fast::Protowire::Message
          class ValueAtQuantile < Fast::Protowire::Message
            field :quantile, :double, 1
            field :value, :double, 2
          end

          field :start_time_unix_nano, :fixed64, 2
          field :time_unix_nano, :fixed64, 3
          field :count, :fixed64, 4
          field :sum, :double, 5
          repeated :quantile_values, ValueAtQuantile, 6
          repeated :attributes, KeyValue, 7
          field :flags, :uint32, 8
        end

        class ExponentialHistogramDataPoint < Fast::Protowire::Message
          class Buckets < Fast::Protowire::Message
            field :offset, :sint32, 1
            repeated :bucket_counts, :uint64, 2
          end

          repeated :attributes, KeyValue, 1
          field :start_time_unix_nano, :fixed64, 2
          field :time_unix_nano, :fixed64, 3
          field :count, :fixed64, 4
          optional :sum, :double, 5
          field :scale, :sint32, 6
          field :zero_count, :fixed64, 7
          field :positive, Buckets, 8
          field :negative, Buckets, 9
          field :flags, :uint32, 10
          optional :min, :double, 12
          optional :max, :double, 13
          field :zero_threshold, :double, 14
        end

        class Gauge < Fast::Protowire::Message
          repeated :data_points, NumberDataPoint, 1
        end

        class Sum < Fast::Protowire::Message
          repeated :data_points, NumberDataPoint, 1
          field :aggregation_temporality, AggregationTemporality, 2
          field :is_monotonic, :bool, 3
        end

        class Histogram < Fast::Protowire::Message
          repeated :data_points, HistogramDataPoint, 1
          field :aggregation_temporality, AggregationTemporality, 2
        end

        class ExponentialHistogram < Fast::Protowire::Message
          repeated :data_points, ExponentialHistogramDataPoint, 1
          field :aggregation_temporality, AggregationTemporality, 2
        end

        class Summary < Fast::Protowire::Message
          repeated :data_points, SummaryDataPoint, 1
        end

        class Metric < Fast::Protowire::Message
          field :name, :string, 1
          field :description, :string, 2
          field :unit, :string, 3
          oneof :data do
            field :gauge, Gauge, 5
            field :sum, Sum, 7
            field :histogram, Histogram, 9
            field :exponential_histogram, ExponentialHistogram, 10
            field :summary, Summary, 11
          end
          repeated :metadata, KeyValue, 12
        end

        class ScopeMetrics < Fast::Protowire::Message
          field :scope, InstrumentationScope, 1
          repeated :metrics, Metric, 2
          field :schema_url, :string, 3
        end

        class ResourceMetrics < Fast::Protowire::Message
          field :resource, Resource, 1
          repeated :scope_metrics, ScopeMetrics, 2
          field :schema_url, :string, 3
        end

        class ExportMetricsServiceRequest < Fast::Protowire::Message
          repeated :resource_metrics, ResourceMetrics, 1
        end

        class ExportMetricsPartialSuccess < Fast::Protowire::Message
          field :rejected_data_points, :int64, 1
          field :error_message, :string, 2
        end

        class ExportMetricsServiceResponse < Fast::Protowire::Message
          field :partial_success, ExportMetricsPartialSuccess, 1
        end
      end
    end
  end
end
