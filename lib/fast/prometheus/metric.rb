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

        @name = name.to_s.to_sym
        @docstring = docstring
        @labels = labels
        @preset_labels = preset_labels.transform_values { |v| v.to_s.freeze }
        @store = store || Store.new

        return unless fully_bound?

        @resolved_key = resolve_internal(@preset_labels)
        seed(@resolved_key)
      end

      attr_reader :name, :docstring, :labels, :preset_labels

      # Returns the current value for the given label set. Scalar types
      # (Counter, Gauge) return 0.0 for unobserved series. Histogram, Summary,
      # and NativeHistogram override this with their own zero-valued shapes.
      def get(labels: {})
        key = resolve(labels)
        store.synchronize { store[key] || 0.0 }
      end

      # Creates the series for +labels+ at its zero value if absent. Never
      # resets a series that already exists. Raises InvalidLabelSet on an
      # unknown or incomplete label set, same as any mutator.
      def init_label_set(labels = {})
        seed(resolve(labels))
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
          labels: @labels,
          preset_labels: merged,
          store: @store,
          **construction_options
        )
      end

      def values
        raw_values
      end

      # Seam for MetricSnapshot: this metric's raw per-series storage objects
      # (Float for Counter/Gauge; the internal slot classes for Histogram,
      # Summary, and NativeHistogram) rather than the public shapes #get and
      # #values return on those three types.
      def raw_values
        store.synchronize { store.to_h.transform_keys { |key| @labels.zip(key).to_h } }
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

        @labels.map do |n|
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

      # Zero value for a fresh series. Counter/Gauge share this Float
      # default; Histogram, Summary, and NativeHistogram override it with
      # their own empty slot.
      def zero_value
        0.0
      end

      # Creates the series at +key+ at its zero value if absent. Never resets
      # a series that already exists. Shared by #initialize (auto-seeding a
      # fully-bound metric) and #init_label_set.
      def seed(key)
        store.synchronize { store[key] ||= zero_value }
      end

      def fully_bound?
        @preset_labels.size == @labels.size
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
          raise InvalidLabelSet, "unknown label name: #{key.inspect}" unless @labels.include?(key)
        end
      end

      def resolve_internal(merged)
        @labels.map { |n| merged.fetch(n) }.freeze
      end
    end
  end
end
