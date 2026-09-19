# frozen_string_literal: true

require "fast/prometheus"
require "protocol/http/middleware"
require "fast/prometheus/exposition"

module Fast
  module Prometheus
    module Middleware
      # Protocol::HTTP middleware that serves metrics at a configurable path.
      # Handles content negotiation (text vs protobuf) and gzip compression.
      class Exporter < Protocol::HTTP::Middleware
        def initialize(delegate, registry: Fast::Prometheus.registry, path: "/metrics")
          super(delegate)
          @registry = registry
          @path = path
          @query_prefix = "#{path}?".freeze
        end

        def call(request)
          return serve_metrics(request) if request.method == "GET" && metrics_target?(request.path)

          super
        end

        private

        # A Protocol::HTTP request target carries its query string ("/metrics?x=1"),
        # unlike Rack's PATH_INFO, so match the path component: the path itself,
        # or the path followed by any query.
        def metrics_target?(target)
          target == @path || target.start_with?(@query_prefix)
        end

        def serve_metrics(request)
          body, headers = Exposition.render(
            @registry,
            accept: request.headers["accept"],
            accept_encoding: request.headers["accept-encoding"]
          )

          Protocol::HTTP::Response[200, Protocol::HTTP::Headers[headers], [body]]
        end
      end
    end
  end
end
