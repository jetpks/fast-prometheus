# frozen_string_literal: true

require "fast/prometheus"
require_relative "metrics_proto"

module Fast
  module Prometheus
    module Formats
      # Prometheus protobuf exposition: a stream of varint-length-prefixed
      # MetricFamily messages.
      #
      # Each family's header is a declared Proto::MetricFamily; the series
      # under it are written straight to the wire with Fast::Protowire::Wire,
      # no LabelPair/Metric/Counter objects, because a scrape's series count
      # is the one thing here that is large. Each series' bytes are written
      # straight into the output behind a length prefix filled in after them,
      # so rendering allocates nothing per series and copies nothing. Native
      # histograms, few and irregular,
      # still go through Proto::Histogram. Bytes are identical to what the
      # declared classes (and google-protobuf) produce; the tests check.
      module Protobuf
        CONTENT_TYPE = "application/vnd.google.protobuf; proto=io.prometheus.client.MetricFamily; encoding=delimited"

        TYPE_MAP = {
          counter: :COUNTER,
          gauge: :GAUGE,
          summary: :SUMMARY,
          histogram: :HISTOGRAM,
          native_histogram: :HISTOGRAM
        }.freeze
        private_constant :TYPE_MAP

        # Field tags for the messages written by hand, read off the
        # declarations so field numbers live in metrics_proto.rb only. All
        # are one byte (field numbers below 16), which the size arithmetic
        # below relies on.
        def self.tag(message_class, field)
          field = message_class.fields.fetch(field)
          Fast::Protowire::Wire.tag(field.number, field.wire_type)
        end
        private_class_method :tag

        FAMILY_METRIC = tag(Proto::MetricFamily, :metric)
        METRIC_LABEL = tag(Proto::Metric, :label)
        METRIC_GAUGE = tag(Proto::Metric, :gauge)
        METRIC_COUNTER = tag(Proto::Metric, :counter)
        METRIC_SUMMARY = tag(Proto::Metric, :summary)
        METRIC_HISTOGRAM = tag(Proto::Metric, :histogram)
        LABEL_NAME = tag(Proto::LabelPair, :name)
        LABEL_VALUE = tag(Proto::LabelPair, :value)
        VALUE = tag(Proto::Counter, :value) # Gauge.value has the same tag
        SUMMARY_COUNT = tag(Proto::Summary, :sample_count)
        SUMMARY_SUM = tag(Proto::Summary, :sample_sum)
        HISTOGRAM_COUNT = tag(Proto::Histogram, :sample_count)
        HISTOGRAM_SUM = tag(Proto::Histogram, :sample_sum)
        HISTOGRAM_BUCKET = tag(Proto::Histogram, :bucket)
        BUCKET_COUNT = tag(Proto::Bucket, :cumulative_count)
        BUCKET_BOUND = tag(Proto::Bucket, :upper_bound)
        private_constant :FAMILY_METRIC, :METRIC_LABEL, :METRIC_GAUGE, :METRIC_COUNTER, :METRIC_SUMMARY,
                         :METRIC_HISTOGRAM, :LABEL_NAME, :LABEL_VALUE, :VALUE, :SUMMARY_COUNT, :SUMMARY_SUM,
                         :HISTOGRAM_COUNT, :HISTOGRAM_SUM, :HISTOGRAM_BUCKET, :BUCKET_COUNT, :BUCKET_BOUND

        # Tag plus eight bytes: what a double field occupies when sent.
        DOUBLE_SIZE = 9
        private_constant :DOUBLE_SIZE

        # One varint-length-prefixed MetricFamily frame per metric, each
        # written straight into the output behind a length prefix reserved
        # first and filled in after (see Fast::Protowire::Wire).
        def self.render(snapshot)
          snapshot.metrics.each_with_object(String.new) do |ms, out|
            start = Fast::Protowire::Wire.reserve_length(out)
            append_metric_family(out, ms)
            Fast::Protowire::Wire.close_length(out, start)
          end
        end

        # A family's bytes are its header (name, help, type) followed by one
        # metric entry per series, in place. A family's series are alike, so
        # the entry prefix width carries from one to the next.
        private_class_method def self.append_metric_family(out, metric_snapshot)
          Proto::MetricFamily.new(name: metric_snapshot.name.name, help: metric_snapshot.docstring,
                                  type: TYPE_MAP.fetch(metric_snapshot.type)).encode(out)
          type = metric_snapshot.type
          names = metric_snapshot.label_names
          width = 1
          metric_snapshot.series.each_pair do |values, value|
            width = Fast::Protowire::Wire.append_length_delimited_from(out, FAMILY_METRIC, width) do |buffer|
              append_metric(buffer, names, values, value, type)
            end
          end
        end

        # Metric: labels (1) then the one value field for the type, in
        # field-number order as the declared encoder would write them.
        private_class_method def self.append_metric(out, names, values, value, type)
          names.each_index { |i| append_label_pair(out, names[i], values[i]) }
          case type
          when :counter then append_scalar_message(out, METRIC_COUNTER, value)
          when :gauge then append_scalar_message(out, METRIC_GAUGE, value)
          when :summary then append_summary(out, value)
          when :histogram then append_histogram(out, value)
          when :native_histogram
            Fast::Protowire::Wire.append_length_delimited(out, METRIC_HISTOGRAM, native_histogram(value).encode)
          end
        end

        # LabelPair { string name = 1; string value = 2 }.
        private_class_method def self.append_label_pair(out, name, value)
          name = name.name if name.is_a?(Symbol)
          value = value.to_s
          name_size = name.bytesize
          value_size = value.bytesize
          out << METRIC_LABEL
          append_varint(out, 2 + varint_size(name_size) + name_size + varint_size(value_size) + value_size)
          Fast::Protowire::Wire.append_length_delimited(out, LABEL_NAME, name)
          Fast::Protowire::Wire.append_length_delimited(out, LABEL_VALUE, value)
        end

        # Counter / Gauge { double value = 1 }: empty when the value is the
        # proto3 default (+0.0 exactly; -0.0 and NaN are sent).
        private_class_method def self.append_scalar_message(out, tag, value)
          out << tag
          if omit_double?(value)
            out << 0
          else
            out << DOUBLE_SIZE
            append_double(out, VALUE, value)
          end
        end

        # Summary { uint64 sample_count = 1; double sample_sum = 2 }.
        private_class_method def self.append_summary(out, value)
          count = value.count
          sum = value.sum
          out << METRIC_SUMMARY
          append_varint(out, uint_size(SUMMARY_COUNT, count) + double_size(sum))
          append_uint(out, SUMMARY_COUNT, count)
          append_double(out, SUMMARY_SUM, sum) unless omit_double?(sum)
        end

        # Histogram { uint64 sample_count = 1; double sample_sum = 2;
        # repeated Bucket bucket = 3 } with Bucket { uint64 cumulative_count
        # = 1; double upper_bound = 2 }. Sizes are summed first, then the
        # bytes are written, so no bucket is encoded into its own buffer.
        private_class_method def self.append_histogram(out, value)
          count = value.count
          sum = value.sum
          buckets = value.cumulative_buckets
          size = uint_size(HISTOGRAM_COUNT, count) + double_size(sum)
          buckets.each do |bound, cumulative|
            bucket_size = bucket_size(bound, cumulative)
            size += 1 + varint_size(bucket_size) + bucket_size
          end

          out << METRIC_HISTOGRAM
          append_varint(out, size)
          append_uint(out, HISTOGRAM_COUNT, count)
          append_double(out, HISTOGRAM_SUM, sum) unless omit_double?(sum)
          buckets.each do |bound, cumulative|
            out << HISTOGRAM_BUCKET
            append_varint(out, bucket_size(bound, cumulative))
            append_uint(out, BUCKET_COUNT, cumulative)
            append_double(out, BUCKET_BOUND, bound) unless omit_double?(bound)
          end
        end

        private_class_method def self.bucket_size(bound, cumulative)
          uint_size(BUCKET_COUNT, cumulative) + double_size(bound)
        end

        # -- wire pieces ------------------------------------------------------

        private_class_method def self.append_varint(out, value)
          Fast::Protowire::Wire.append_varint(out, value)
        end

        # A uint64 field, omitted at zero.
        private_class_method def self.append_uint(out, tag, value)
          return if value.zero?

          out << tag
          append_varint(out, value)
        end

        private_class_method def self.append_double(out, tag, value)
          out << tag
          [value].pack("E", buffer: out)
        end

        private_class_method def self.uint_size(_tag, value)
          value.zero? ? 0 : 1 + varint_size(value)
        end

        private_class_method def self.double_size(value)
          omit_double?(value) ? 0 : DOUBLE_SIZE
        end

        # Bytes a non-negative varint takes.
        private_class_method def self.varint_size(value)
          size = 1
          while value > 0x7f
            value >>= 7
            size += 1
          end
          size
        end

        # Implicit presence: +0.0 is not sent; -0.0 (bitwise different) is.
        private_class_method def self.omit_double?(value)
          value.zero? && (1.0 / value).positive?
        end

        # -- native histograms, through the declared classes ------------------

        private_class_method def self.native_histogram(value)
          pos_spans, pos_deltas = build_spans_deltas(value.positive_buckets)
          neg_spans, neg_deltas = build_spans_deltas(value.negative_buckets)

          Proto::Histogram.new(
            sample_count: value.count,
            sample_sum: value.sum,
            schema: value.schema,
            zero_threshold: value.zero_threshold,
            zero_count: value.zero_count,
            positive_span: pos_spans,
            positive_delta: pos_deltas,
            negative_span: neg_spans,
            negative_delta: neg_deltas
          )
        end

        # Build BucketSpan and sint64 delta arrays from ascending [index, count] pairs.
        # Worked example: [[1, 3], [2, 1], [5, 4]] ->
        #   spans: [{offset: 1, length: 2}, {offset: 2, length: 1}]
        #   deltas: [3, -2, 3]
        private_class_method def self.build_spans_deltas(buckets)
          return [], [] if buckets.empty?

          spans = []
          deltas = []
          span_offset = nil
          span_length = 0
          prev_index = nil
          prev_count = nil

          buckets.each do |index, count|
            if prev_index.nil?
              span_offset = index
              span_length = 1
              deltas << count
            else
              gap = index - prev_index
              if gap == 1
                span_length += 1
              else
                spans << Proto::BucketSpan.new(offset: span_offset, length: span_length)
                span_offset = gap - 1
                span_length = 1
              end
              deltas << count - prev_count
            end
            prev_index = index
            prev_count = count
          end

          spans << Proto::BucketSpan.new(offset: span_offset, length: span_length)
          [spans, deltas]
        end
      end
    end
  end
end
