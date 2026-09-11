# frozen_string_literal: true

require "fast/prometheus"

module Fast
  module Prometheus
    # Owns the RED metrics (request count + duration) recorded for every HTTP
    # request. Shared by Middleware::Instrumentation and Rack::Instrumentation
    # so registration and recording exist exactly once.
    class RequestMetrics
      def initialize(registry:, native: false, prefix: "http_server")
        @registry = registry
        @counter = ensure_counter(prefix)
        @histogram = ensure_histogram(prefix, native)
      end

      def record(method, status, started_at)
        labels = { method: method, status: status }
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        @counter.increment(labels: labels)
        @histogram.observe(duration, labels: labels)
      end

      private

      def ensure_counter(prefix)
        name = :"#{prefix}_requests_total"
        @registry.fetch_or_register(name) do
          Counter.new(name, docstring: "Total HTTP requests", labels: %i[method status])
        end
      end

      def ensure_histogram(prefix, native)
        name = :"#{prefix}_request_duration_seconds"
        @registry.fetch_or_register(name) do
          if native
            NativeHistogram.new(name, docstring: "HTTP request duration in seconds", labels: %i[method status])
          else
            Histogram.new(name, docstring: "HTTP request duration in seconds", labels: %i[method status])
          end
        end
      end
    end
  end
end
