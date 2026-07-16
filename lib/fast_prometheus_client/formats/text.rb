# frozen_string_literal: true

module FastPrometheusClient
  module Formats
    # Prometheus text exposition format 0.0.4.
    # Consumes Snapshot value objects; never reads live metrics.
    module Text
      CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

      DOC_ESCAPE  = /[\n\\]/
      DOC_REPLACE = { "\n" => "\\n", "\\" => "\\\\" }.freeze

      LABEL_ESCAPE = /[\n\\"]/
      LABEL_REPLACE = { "\\" => "\\\\", '"' => '\\"', "\n" => "\\n" }.freeze

      def self.render(snapshot)
        parts = []

        snapshot.metrics.each do |metric|
          next if metric.type == :native_histogram

          parts << "# HELP #{metric.name} #{escape_doc(metric.docstring)}"
          parts << "# TYPE #{metric.name} #{metric.type}"

          metric.series.each do |series|
            case metric.type
            when :counter, :gauge
              parts << metric_line(metric.name, series.labels, series.value)
            when :histogram
              histogram_lines(metric.name, series.labels, series.value, parts)
            when :summary
              summary_lines(metric.name, series.labels, series.value, parts)
            end
          end
        end

        "#{parts.join("\n")}\n"
      end

      def self.escape_doc(string)
        string.gsub(DOC_ESCAPE, DOC_REPLACE)
      end

      def self.escape_label(string)
        string.to_s.gsub(LABEL_ESCAPE, LABEL_REPLACE)
      end

      def self.format_labels(labels)
        return "" if labels.empty?

        strings = labels.map do |key, value|
          "#{key}=\"#{escape_label(value)}\""
        end

        "{#{strings.join(',')}}"
      end

      def self.metric_line(name, labels, value)
        "#{name}#{format_labels(labels)} #{value}"
      end

      def self.histogram_lines(name, labels, value, parts)
        value.cumulative_buckets.each do |boundary, count|
          le = boundary.infinite? ? "+Inf" : boundary.to_s
          merged = labels.merge("le" => le)
          parts << metric_line("#{name}_bucket", merged, count)
        end

        parts << metric_line("#{name}_sum", labels, value.sum)
        parts << metric_line("#{name}_count", labels, value.count)
      end

      def self.summary_lines(name, labels, value, parts)
        parts << metric_line("#{name}_sum", labels, value.sum)
        parts << metric_line("#{name}_count", labels, value.count)
      end
    end
  end
end
