# frozen_string_literal: true

require "fast/prometheus"
require "protocol/http/middleware"
require "fast/prometheus/request_metrics"

module Fast
  module Prometheus
    module Middleware
      # Protocol::HTTP middleware that records RED metrics for every request.
      # Drop one line into a Falcon app and get request counts and durations.
      class Instrumentation < Protocol::HTTP::Middleware
        def initialize(delegate, registry: Fast::Prometheus.registry, native: false, prefix: "http_server")
          super(delegate)
          @metrics = RequestMetrics.new(registry: registry, native: native, prefix: prefix)
        end

        def call(request)
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = super
          @metrics.record(request.method, response.status.to_s, start)
          response
        rescue StandardError => e
          begin
            @metrics.record(request.method, "500", start)
          rescue StandardError
            nil
          end
          raise e
        end
      end
    end
  end
end
