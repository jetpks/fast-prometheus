# frozen_string_literal: true

require "protocol/http/middleware"

module FastPrometheusClient
  module Middleware
    # Protocol::HTTP middleware that records RED metrics for every request.
    # Drop one line into a Falcon app and get request counts and durations.
    class Instrumentation < Protocol::HTTP::Middleware
      def initialize(delegate, registry: FastPrometheusClient.registry, native: false, prefix: "http_server")
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
      rescue StandardError
        record(request.method, "500", start)
        raise
      end

      private

      def record(method, status, start)
        labels = { method: method, status: status }
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        @counter.increment(labels: labels)
        @histogram.observe(duration, labels: labels)
      end

      def ensure_counter
        name = "#{@prefix}_requests_total".to_sym
        @registry.get(name) || @registry.counter(name, docstring: "Total HTTP requests", labels: %i[method status])
      end

      def ensure_histogram
        name = "#{@prefix}_request_duration_seconds".to_sym
        existing = @registry.get(name)
        return existing if existing

        if @native
          @registry.native_histogram(name, docstring: "HTTP request duration in seconds", labels: %i[method status])
        else
          @registry.histogram(name, docstring: "HTTP request duration in seconds", labels: %i[method status])
        end
      end
    end
  end
end
