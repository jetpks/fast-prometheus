# frozen_string_literal: true

require_relative "errors"
require_relative "store"

module Fast
  module Prometheus
    # Metric is the abstract base class for all metric types.
    #
    # Every metric's per-series storage is a Store, guarded by its own lock.
    # Metrics produced by #with_labels share their parent's Store (and thus
    # its lock), so a mutation on a bound metric and a mutation on its parent
    # are mutually exclusive. Safe to share across OS threads and fibers.
    class Metric
      METRIC_NAME = /\A[a-zA-Z_:][a-zA-Z0-9_:]*\z/
      LABEL_NAME = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

      def initialize(name, docstring:, labels: [], preset_labels: {}, store: nil)
        validate_metric_name(name)
        validate_docstring(docstring)
        validate_label_names(labels)
        validate_preset_labels(labels, preset_labels)

        @name = name
        @docstring = docstring
        @label_names = labels
        @preset_labels = preset_labels.transform_values { |v| v.to_s.freeze }
        @store = store || Store.new

        return unless fully_bound?

        @resolved_key = resolve_internal(@preset_labels)
      end

      attr_reader :name, :docstring, :label_names, :preset_labels

      # Returns the current value for the given label set.
      # Scalar types (Counter, Gauge) return 0.0 for unobserved series.
      # Slot-based types (Histogram, Summary, NativeHistogram) override to return nil.
      def get(labels: {})
        key = resolve(labels)
        store.synchronize { store[key] || 0.0 }
      end

      def type
        raise NotImplementedError, "subclasses must implement #type"
      end

      def with_labels(**labels)
        validate_label_keys(labels)
        merged = @preset_labels.merge(labels.transform_values { |v| v.to_s.freeze })
        self.class.new(
          @name,
          docstring: @docstring,
          labels: @label_names,
          preset_labels: merged,
          store: @store,
          **construction_options
        )
      end

      def values
        store.synchronize { store.to_h.transform_keys { |key| @label_names.zip(key).to_h } }
      end

      # Runs +block+ exclusively with respect to every other mutation or read
      # of this metric's store (including on metrics sharing it via
      # #with_labels). Reentrant on the same thread. This is the seam
      # MetricSnapshot uses to build a consistent snapshot of every series.
      def synchronize(&block)
        store.synchronize(&block)
      end

      protected

      attr_reader :store

      # Subclasses override to forward their own configuration (e.g. buckets,
      # schema) through #with_labels. See Histogram, NativeHistogram.
      def construction_options
        {}
      end

      def resolve(labels)
        return @resolved_key if @resolved_key && labels.empty?

        validate_label_keys(labels)

        @label_names.map do |n|
          if labels.key?(n)
            labels[n].to_s
          else
            value = @preset_labels[n]
            raise InvalidLabelSet, "missing labels: #{n.inspect}" unless value

            value
          end
        end.freeze
      end

      private

      def fully_bound?
        @preset_labels.size == @label_names.size
      end

      def validate_metric_name(name)
        return if name.to_s.match?(METRIC_NAME)

        raise InvalidMetricName, "invalid metric name: #{name.inspect}"
      end

      def validate_docstring(docstring)
        return if docstring.is_a?(String) && !docstring.empty?

        raise ArgumentError, "docstring must be a non-empty string"
      end

      def validate_label_names(labels)
        labels.each do |label|
          name = label.to_s
          raise InvalidLabelName, "label name must not start with __: #{label.inspect}" if name.start_with?("__")
          raise InvalidLabelName, "invalid label name: #{label.inspect}" unless name.match?(LABEL_NAME)
        end
      end

      def validate_preset_labels(labels, preset_labels)
        preset_labels.each_key do |key|
          raise InvalidLabelSet, "preset label not in declared labels: #{key.inspect}" unless labels.include?(key)
        end
      end

      def validate_label_keys(labels)
        labels.each_key do |key|
          raise InvalidLabelSet, "unknown label name: #{key.inspect}" unless @label_names.include?(key)
        end
      end

      def resolve_internal(merged)
        @label_names.map { |n| merged.fetch(n) }.freeze
      end
    end
  end
end
