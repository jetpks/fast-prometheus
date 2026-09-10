# frozen_string_literal: true

require "fast/prometheus"
require "protocol/http/middleware"

module Fast
  module Prometheus
    module Middleware
      # Protocol::HTTP middleware that records RED metrics for every request.
      # Drop one line into a Falcon app and get request counts and durations.
      class Instrumentation < Protocol::HTTP::Middleware
        def initialize(delegate, registry: Fast::Prometheus.registry, native: false, prefix: "http_server")
          super(delegate)
          @registry = registry
          @native = native
          @prefix = prefix
          @counter = ensure_counter
          @histogram = ensure_histogram
        end

        def call(request)
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = super
          record(request.method, response.status.to_s, start)
          response
        rescue StandardError => e
          begin
            record(request.method, "500", start)
          rescue StandardError
            nil
          end
          raise e
        end

        private

        def record(method, status, start)
          labels = { method: method, status: status }
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          @counter.increment(labels: labels)
          @histogram.observe(duration, labels: labels)
        end

        def ensure_counter
          name = :"#{@prefix}_requests_total"
          @registry.fetch_or_register(name) do
            Counter.new(name, docstring: "Total HTTP requests", labels: %i[method status])
          end
        end

        def ensure_histogram
          name = :"#{@prefix}_request_duration_seconds"
          @registry.fetch_or_register(name) do
            if @native
              NativeHistogram.new(name, docstring: "HTTP request duration in seconds", labels: %i[method status])
            else
              Histogram.new(name, docstring: "HTTP request duration in seconds", labels: %i[method status])
            end
          end
        end
      end
    end
  end
end
