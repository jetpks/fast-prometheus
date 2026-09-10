# frozen_string_literal: true

require_relative "errors"
require_relative "counter"
require_relative "gauge"
require_relative "histogram"
require_relative "summary"
require_relative "native_histogram"
require_relative "snapshot"

module Fast
  module Prometheus
    # Registry holds a collection of metrics and produces immutable snapshots.
    class Registry
      def initialize
        @by_name = {}
        @lock = Mutex.new
      end

      # Register a metric. Raises DuplicateMetric if a metric with the same name
      # is already registered. Returns the metric.
      def register(metric)
        @lock.synchronize do
          raise DuplicateMetric, "metric #{metric.name} already registered" if @by_name.key?(metric.name)

          @by_name[metric.name] = metric
          metric
        end
      end

      # Remove a metric by name.
      def unregister(name)
        @lock.synchronize { @by_name.delete(name) }
      end

      # Look up a metric by name, or nil.
      def get(name)
        @lock.synchronize { @by_name[name] }
      end

      # Return the registered metrics, insertion order.
      def metrics
        @lock.synchronize { @by_name.values }
      end

      # Convenience: build, register, and return a Counter.
      def counter(name, **kwargs)
        register(Counter.new(name, **kwargs))
      end

      # Convenience: build, register, and return a Gauge.
      def gauge(name, **kwargs)
        register(Gauge.new(name, **kwargs))
      end

      # Convenience: build, register, and return a Histogram.
      def histogram(name, **kwargs)
        register(Histogram.new(name, **kwargs))
      end

      # Convenience: build, register, and return a Summary.
      def summary(name, **kwargs)
        register(Summary.new(name, **kwargs))
      end

      # Convenience: build, register, and return a NativeHistogram.
      def native_histogram(name, **kwargs)
        register(NativeHistogram.new(name, **kwargs))
      end

      # Collect an immutable snapshot of all registered metrics.
      def collect
        @lock.synchronize { Snapshot.of(@by_name.values) }
      end
    end

    @registry_lock = Mutex.new

    # Module-level default registry. Constructed at most once across threads:
    # the fast path is an unsynchronized read (safe under the GVL), and only
    # the first caller pays for the lock.
    def self.registry
      @registry || @registry_lock.synchronize { @registry ||= Registry.new }
    end

    def self.registry=(registry)
      @registry = registry
    end
  end
end
