# frozen_string_literal: true

require "fast/prometheus"

module Fast
  module Prometheus
    module Formats
      # Prometheus text exposition format 0.0.4.
      # Consumes Snapshot value objects; never reads live metrics.
      #
      # Every piece is appended straight to the output buffer: no line, label
      # or name is built as its own String first, so a render allocates one
      # String per sample (the value's to_s) and nothing per label.
      module Text
        CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

        DOC_ESCAPE  = /[\n\\]/
        DOC_REPLACE = { "\n" => "\\n", "\\" => "\\\\" }.freeze

        LABEL_ESCAPE = /[\n\\"]/
        LABEL_REPLACE = { "\\" => "\\\\", '"' => '\\"', "\n" => "\\n" }.freeze

        def self.render(snapshot)
          snapshot.metrics.each_with_object(String.new) do |metric, output|
            next if metric.type == :native_histogram

            name = metric.name.name
            output << "# HELP " << name << " " << escape_doc(metric.docstring) << "\n"
            output << "# TYPE " << name << " " << metric.type.name << "\n"

            names = metric.label_names
            metric.series.each_pair do |values, value|
              render_series(output, metric.type, name, names, values, value)
            end
          end
        end

        private_class_method def self.render_series(output, type, name, names, values, value)
          case type
          when :counter, :gauge
            sample(output, name, nil, names, values, value)
          when :histogram
            histogram_lines(output, name, names, values, value)
          when :summary
            sample(output, name, "_sum", names, values, value.sum)
            sample(output, name, "_count", names, values, value.count)
          end
        end

        # One sample line: name, optional suffix, labels (names and values
        # side by side, plus an le label carrying +upper_bound+ for histogram
        # buckets), value.
        private_class_method def self.sample(output, name, suffix, names, values, value, upper_bound = nil)
          output << name
          output << suffix if suffix
          append_labels(output, names, values, upper_bound)
          output << " " << value.to_s << "\n"
        end

        private_class_method def self.append_labels(output, names, values, upper_bound)
          return if names.empty? && upper_bound.nil?

          output << "{"
          names.each_index { |i| output << label_name(names[i]) << "=\"" << escape_label(values[i]) << "\"," }
          output << "le=\"" << upper_bound << "\"," if upper_bound
          output.chop!
          output << "}"
        end

        private_class_method def self.histogram_lines(output, name, names, values, value)
          value.cumulative_buckets.each do |boundary, count|
            sample(output, name, "_bucket", names, values, count, boundary.infinite? ? "+Inf" : boundary.to_s)
          end

          sample(output, name, "_sum", names, values, value.sum)
          sample(output, name, "_count", names, values, value.count)
        end

        # Label names are Symbols (Symbol#name is frozen and shared); a
        # String name is appended as is.
        private_class_method def self.label_name(key)
          key.is_a?(Symbol) ? key.name : key
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
      end
    end
  end
end
