# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/request_metrics"

module Fast
  module Prometheus
    module Rack
      # Rack middleware that records RED metrics for every request.
      # Drop one line into config.ru and get request counts and durations.
      class Instrumentation
        def initialize(app, registry: Fast::Prometheus.registry, native: false, prefix: "http_server")
          @app = app
          @metrics = RequestMetrics.new(registry: registry, native: native, prefix: prefix)
        end

        def call(env)
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status, headers, body = @app.call(env)
          @metrics.record(env["REQUEST_METHOD"], status.to_s, start)
          [status, headers, body]
        rescue StandardError => e
          begin
            @metrics.record(env["REQUEST_METHOD"], "500", start)
          rescue StandardError
            nil
          end
          raise e
        end
      end
    end
  end
end
