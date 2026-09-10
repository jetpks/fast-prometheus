# frozen_string_literal: true

require "monitor"

module Fast
  module Prometheus
    # Store holds one metric's per-series data plus the lock guarding it.
    # Metrics produced by Metric#with_labels share their parent's Store (and
    # therefore its lock) via the store: keyword.
    #
    # Monitor is reentrant: a thread already inside #synchronize (e.g. a
    # derived reader delegating to another locked method, or Metric#synchronize
    # driving MetricSnapshot.of) can re-enter without deadlocking itself.
    class Store
      def initialize
        @data = {}
        @monitor = Monitor.new
      end

      def synchronize(&block)
        @monitor.synchronize(&block)
      end

      def [](key)
        @data[key]
      end

      def []=(key, value)
        @data[key] = value
      end

      def to_h
        @data
      end
    end
  end
end
