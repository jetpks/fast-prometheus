# frozen_string_literal: true

require_relative "errors"

module FastPrometheusClient
  # Metric is the abstract base class for all metric types.
  #
  # Fiber-atomicity invariant: metric updates perform no blocking operations
  # between reading and writing a storage slot. Under cooperative scheduling
  # (Async/IO), plain Hash read-modify-write is fiber-atomic with no mutex.
  # Cross-thread use is out of contract — if you need thread safety, use
  # Ruby's Monitor or Mutex externally.
  class Metric
    METRIC_NAME = /\A[a-zA-Z_:][a-zA-Z0-9_:]*\z/
    LABEL_NAME = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    def initialize(name, docstring:, labels: [], preset_labels: {})
      validate_metric_name(name)
      validate_docstring(docstring)
      validate_label_names(labels)
      validate_preset_labels(labels, preset_labels)

      @name = name
      @docstring = docstring
      @label_names = labels
      @preset_labels = preset_labels.transform_values { |v| v.to_s.freeze }
      @store = {}

      return unless fully_bound?

      @resolved_key = resolve_internal(@preset_labels)
    end

    attr_reader :name, :docstring, :label_names, :preset_labels, :store

    def type
      raise NotImplementedError, "subclasses must implement #type"
    end

    def with_labels(**labels)
      validate_with_labels(labels)
      merged = @preset_labels.merge(labels.transform_values { |v| v.to_s.freeze })
      self.class.new(
        @name,
        docstring: @docstring,
        labels: @label_names,
        preset_labels: merged
      ).tap { |m| m.instance_variable_set(:@store, @store) }
    end

    def values
      @store.transform_keys { |key| @label_names.zip(key).to_h }
    end

    protected

    def resolve(labels)
      return @resolved_key if @resolved_key && labels.empty?

      validate_resolve_labels(labels)
      merged = @preset_labels.merge(labels.transform_values(&:to_s))
      validate_resolve_completeness(merged)
      resolve_internal(merged)
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
      labels_set = labels.to_set
      preset_labels.each_key do |key|
        raise InvalidLabelSet, "preset label not in declared labels: #{key.inspect}" unless labels_set.include?(key)
      end
    end

    def validate_with_labels(labels)
      labels.each_key do |key|
        raise InvalidLabelSet, "unknown label name: #{key.inspect}" unless @label_names.include?(key)
      end
    end

    def validate_resolve_labels(labels)
      labels.each_key do |key|
        raise InvalidLabelSet, "unknown label name: #{key.inspect}" unless @label_names.include?(key)
      end
    end

    def validate_resolve_completeness(merged)
      missing = @label_names.reject { |n| merged.key?(n) }
      return if missing.empty?

      raise InvalidLabelSet, "missing labels: #{missing.inspect}"
    end

    def resolve_internal(merged)
      @label_names.map { |n| merged.fetch(n) }.freeze
    end
  end
end
