# frozen_string_literal: true

require "fast/prometheus"
require_relative "metrics_proto"

module Fast
  module Prometheus
    module Formats
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

        # MetricFamily.metric is field 4, wire type 2 (length-delimited).
        METRIC_TAG = Fast::Protowire::Wire.tag(4, Fast::Protowire::Wire::LENGTH_DELIMITED)
        private_constant :METRIC_TAG

        # One varint-length-prefixed MetricFamily frame per metric.
        def self.render(snapshot)
          snapshot.metrics.each_with_object(String.new) do |ms, buffer|
            family = encode_metric_family(ms)
            Fast::Protowire::Wire.append_varint(buffer, family.bytesize)
            buffer << family
          end
        end

        # A family's bytes are its header (name, help, type) followed by one
        # field-4 entry per series, each Metric encoded and dropped as it
        # goes, so a family of any size is never one object graph.
        private_class_method def self.encode_metric_family(metric_snapshot)
          header = Proto::MetricFamily.new(name: metric_snapshot.name.to_s, help: metric_snapshot.docstring,
                                           type: TYPE_MAP.fetch(metric_snapshot.type))
          metric_snapshot.series.each_with_object(header.encode) do |series, buffer|
            Fast::Protowire::Wire.append_length_delimited(buffer, METRIC_TAG,
                                                          build_metric(series, metric_snapshot.type).encode)
          end
        end

        private_class_method def self.build_metric(series, type)
          labels = series.labels.map { |name, value| Proto::LabelPair.new(name: name.name, value: value) }

          case type
          when :counter
            Proto::Metric.new(label: labels, counter: Proto::Counter.new(value: series.value))
          when :gauge
            Proto::Metric.new(label: labels, gauge: Proto::Gauge.new(value: series.value))
          when :summary
            Proto::Metric.new(
              label: labels,
              summary: Proto::Summary.new(sample_count: series.value.count, sample_sum: series.value.sum)
            )
          when :histogram
            buckets = series.value.cumulative_buckets.map do |bound, count|
              Proto::Bucket.new(upper_bound: bound, cumulative_count: count)
            end
            Proto::Metric.new(
              label: labels,
              histogram: Proto::Histogram.new(sample_count: series.value.count, sample_sum: series.value.sum,
                                              bucket: buckets)
            )
          when :native_histogram
            nv = series.value
            pos_spans, pos_deltas = build_spans_deltas(nv.positive_buckets)
            neg_spans, neg_deltas = build_spans_deltas(nv.negative_buckets)

            Proto::Metric.new(
              label: labels,
              histogram: Proto::Histogram.new(
                sample_count: nv.count,
                sample_sum: nv.sum,
                schema: nv.schema,
                zero_threshold: nv.zero_threshold,
                zero_count: nv.zero_count,
                positive_span: pos_spans,
                positive_delta: pos_deltas,
                negative_span: neg_spans,
                negative_delta: neg_deltas
              )
            )
          end
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
