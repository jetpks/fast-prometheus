# frozen_string_literal: true

require_relative "metrics_pb"

module FastPrometheusClient
  module Formats
    module Protobuf
      CONTENT_TYPE = "application/vnd.google.protobuf; proto=io.prometheus.client.MetricFamily; encoding=delimited"

      TYPE_MAP = {
        counter: Io::Prometheus::Client::MetricType::COUNTER,
        gauge: Io::Prometheus::Client::MetricType::GAUGE,
        summary: Io::Prometheus::Client::MetricType::SUMMARY,
        histogram: Io::Prometheus::Client::MetricType::HISTOGRAM,
        native_histogram: Io::Prometheus::Client::MetricType::HISTOGRAM
      }.freeze
      private_constant :TYPE_MAP

      def self.render(snapshot)
        snapshot.metrics.each_with_object(String.new) do |ms, buffer|
          buffer << encode_frame(build_metric_family(ms))
        end
      end

      def self.build_metric_family(metric_snapshot)
        Io::Prometheus::Client::MetricFamily.new(
          name: metric_snapshot.name.to_s,
          help: metric_snapshot.docstring,
          type: TYPE_MAP.fetch(metric_snapshot.type),
          metric: metric_snapshot.series.map { |s| build_metric(s, metric_snapshot.type) }
        )
      end

      def self.build_metric(series, type)
        labels = series.labels.map do |name, value|
          Io::Prometheus::Client::LabelPair.new(name: name.to_s, value: value)
        end

        case type
        when :counter
          Io::Prometheus::Client::Metric.new(
            label: labels,
            counter: Io::Prometheus::Client::Counter.new(value: series.value)
          )
        when :gauge
          Io::Prometheus::Client::Metric.new(
            label: labels,
            gauge: Io::Prometheus::Client::Gauge.new(value: series.value)
          )
        when :summary
          Io::Prometheus::Client::Metric.new(
            label: labels,
            summary: Io::Prometheus::Client::Summary.new(
              sample_count: series.value.count,
              sample_sum: series.value.sum
            )
          )
        when :histogram
          buckets = series.value.cumulative_buckets.map do |bound, count|
            Io::Prometheus::Client::Bucket.new(
              upper_bound: bound,
              cumulative_count: count
            )
          end
          Io::Prometheus::Client::Metric.new(
            label: labels,
            histogram: Io::Prometheus::Client::Histogram.new(
              sample_count: series.value.count,
              sample_sum: series.value.sum,
              bucket: buckets
            )
          )
        when :native_histogram
          nv = series.value
          pos_spans, pos_deltas = build_spans_deltas(nv.positive_buckets)
          neg_spans, neg_deltas = build_spans_deltas(nv.negative_buckets)

          Io::Prometheus::Client::Metric.new(
            label: labels,
            histogram: Io::Prometheus::Client::Histogram.new(
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
      def self.build_spans_deltas(buckets)
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
              spans << Io::Prometheus::Client::BucketSpan.new(offset: span_offset, length: span_length)
              span_offset = gap - 1
              span_length = 1
            end
            deltas << count - prev_count
          end
          prev_index = index
          prev_count = count
        end

        spans << Io::Prometheus::Client::BucketSpan.new(offset: span_offset, length: span_length)
        [spans, deltas]
      end

      private_class_method def self.encode_frame(message)
        encoded = message.class.encode(message)
        encode_varint(encoded.bytesize) << encoded
      end

      private_class_method def self.encode_varint(value)
        buffer = String.new
        loop do
          byte = value & 0x7f
          value >>= 7
          byte |= 0x80 if value.positive?
          buffer << byte
          break if value.zero?
        end
        buffer
      end
    end
  end
end
