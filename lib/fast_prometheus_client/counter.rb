# frozen_string_literal: true

require_relative "metric"

module FastPrometheusClient
  # Counter — a monotonically increasing metric.
  class Counter < Metric
    def type
      :counter
    end

    def increment(by: 1, labels: {})
      raise ArgumentError, "by must be a non-negative numeric" unless by.is_a?(Numeric) && by >= 0
      return if by.zero?

      key = resolve(labels)
      store[key] = (store[key] || 0.0) + by.to_f
    end

    def get(labels: {})
      key = resolve(labels)
      store[key] || 0.0
    end
  end
end
