# frozen_string_literal: true

require_relative "metric"

module Fast
  module Prometheus
    # Gauge — an instantaneous value that can go up or down.
    class Gauge < Metric
      def type
        :gauge
      end

      def set(value, labels: {})
        raise ArgumentError, "value must be a numeric" unless value.is_a?(Numeric)

        key = resolve(labels)
        store[key] = value.to_f
      end

      def increment(by: 1, labels: {})
        raise ArgumentError, "by must be a numeric" unless by.is_a?(Numeric)
        return if by.zero?

        key = resolve(labels)
        store[key] = (store[key] || 0.0) + by.to_f
      end

      def decrement(by: 1, labels: {})
        raise ArgumentError, "by must be a numeric" unless by.is_a?(Numeric)
        return if by.zero?

        key = resolve(labels)
        store[key] = (store[key] || 0.0) - by.to_f
      end
    end
  end
end
