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

      # Atomic fetch-or-register: returns the metric already registered under
      # +name+, else registers and returns the block's metric. The block runs
      # only when +name+ is absent, inside the same lock hold as the lookup,
      # so concurrent callers for one absent name never race each other into
      # DuplicateMetric. Raises ArgumentError if the block's metric is not
      # named +name+.
      def fetch_or_register(name)
        @lock.synchronize do
          next @by_name[name] if @by_name.key?(name)

          metric = yield
          unless metric.name == name
            raise ArgumentError, "fetch_or_register(#{name.inspect}) block built #{metric.name.inspect}"
          end

          @by_name[name] = metric
        end
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

      # Collect an immutable snapshot of all registered metrics. The registry
      # lock only covers copying the metric list; each metric's own snapshot
      # is built under its own store lock (see Snapshot.of).
      def collect
        Snapshot.of(metrics)
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
