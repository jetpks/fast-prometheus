# frozen_string_literal: true

require "fast/protowire"

module Fast
  module Prometheus
    module Formats
      module Protobuf
        # The Prometheus client data model (proto/metrics.proto,
        # io.prometheus.client) declared for the wire. The checked-in proto
        # is proto3, so scalars have implicit presence and a zero value is
        # omitted. Only the fields the exposition emits or a scraper reads
        # back are declared; exemplars and created timestamps ride along as
        # unknown fields.
        module Proto
          MetricType = Fast::Protowire::Enum.define(COUNTER: 0, GAUGE: 1, SUMMARY: 2, UNTYPED: 3, HISTOGRAM: 4,
                                                    GAUGE_HISTOGRAM: 5)

          class LabelPair < Fast::Protowire::Message
            field :name, :string, 1
            field :value, :string, 2
          end

          class Gauge < Fast::Protowire::Message
            field :value, :double, 1
          end

          class Counter < Fast::Protowire::Message
            field :value, :double, 1
          end

          class Quantile < Fast::Protowire::Message
            field :quantile, :double, 1
            field :value, :double, 2
          end

          class Summary < Fast::Protowire::Message
            field :sample_count, :uint64, 1
            field :sample_sum, :double, 2
            repeated :quantile, Quantile, 3
          end

          class Untyped < Fast::Protowire::Message
            field :value, :double, 1
          end

          class Bucket < Fast::Protowire::Message
            field :cumulative_count, :uint64, 1
            field :upper_bound, :double, 2
            field :cumulative_count_float, :double, 4
          end

          class BucketSpan < Fast::Protowire::Message
            field :offset, :sint32, 1
            field :length, :uint32, 2
          end

          class Histogram < Fast::Protowire::Message
            field :sample_count, :uint64, 1
            field :sample_sum, :double, 2
            repeated :bucket, Bucket, 3
            field :sample_count_float, :double, 4
            field :schema, :sint32, 5
            field :zero_threshold, :double, 6
            field :zero_count, :uint64, 7
            field :zero_count_float, :double, 8
            repeated :negative_span, BucketSpan, 9
            repeated :negative_delta, :sint64, 10
            repeated :negative_count, :double, 11
            repeated :positive_span, BucketSpan, 12
            repeated :positive_delta, :sint64, 13
            repeated :positive_count, :double, 14
          end

          class Metric < Fast::Protowire::Message
            repeated :label, LabelPair, 1
            field :gauge, Gauge, 2
            field :counter, Counter, 3
            field :summary, Summary, 4
            field :untyped, Untyped, 5
            field :timestamp_ms, :int64, 6
            field :histogram, Histogram, 7
          end

          class MetricFamily < Fast::Protowire::Message
            field :name, :string, 1
            field :help, :string, 2
            field :type, MetricType, 3
            repeated :metric, Metric, 4
          end
        end
      end
    end
  end
end
