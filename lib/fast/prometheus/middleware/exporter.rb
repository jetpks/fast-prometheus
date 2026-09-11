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
        end

        def call(request)
          return serve_metrics(request) if request.method == "GET" && request.path == @path

          super
        end

        private

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
