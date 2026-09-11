# frozen_string_literal: true

require "fast/prometheus"

module Fast
  module Prometheus
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
          snapshot.metrics.each_with_object(String.new) do |metric, output|
            next if metric.type == :native_histogram

            output << "# HELP #{metric.name} #{escape_doc(metric.docstring)}\n"
            output << "# TYPE #{metric.name} #{metric.type}\n"

            metric.series.each do |series|
              render_series(output, metric.type, metric.name, series)
            end
          end
        end

        private_class_method def self.render_series(output, type, name, series)
          case type
          when :counter, :gauge
            metric_line(output, name, series.labels, series.value)
          when :histogram
            histogram_lines(output, name, series.labels, series.value)
          when :summary
            summary_lines(output, name, series.labels, series.value)
          end
        end

        private_class_method def self.escape_doc(string)
          return string unless DOC_ESCAPE.match?(string)

          string.gsub(DOC_ESCAPE, DOC_REPLACE)
        end

        private_class_method def self.escape_label(string)
          string = string.to_s
          return string unless LABEL_ESCAPE.match?(string)

          string.gsub(LABEL_ESCAPE, LABEL_REPLACE)
        end

        private_class_method def self.format_labels(labels)
          return "" if labels.empty?

          output = String.new("{")
          labels.each do |key, value|
            output << "#{key}=\"#{escape_label(value)}\""
            output << ","
          end
          output.chop!
          output << "}"
          output
        end

        private_class_method def self.metric_line(output, name, labels, value)
          output << "#{name}#{format_labels(labels)} #{value}\n"
        end

        private_class_method def self.histogram_lines(output, name, labels, value)
          value.cumulative_buckets.each do |boundary, count|
            le = boundary.infinite? ? "+Inf" : boundary.to_s
            metric_line(output, "#{name}_bucket", labels.merge("le" => le), count)
          end

          metric_line(output, "#{name}_sum", labels, value.sum)
          metric_line(output, "#{name}_count", labels, value.count)
        end

        private_class_method def self.summary_lines(output, name, labels, value)
          metric_line(output, "#{name}_sum", labels, value.sum)
          metric_line(output, "#{name}_count", labels, value.count)
        end
      end
    end
  end
end
