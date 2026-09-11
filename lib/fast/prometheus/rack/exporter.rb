# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/exposition"

module Fast
  module Prometheus
    module Rack
      # Rack middleware that serves metrics at a configurable path.
      # Handles content negotiation (text vs protobuf) and gzip compression.
      class Exporter
        def initialize(app, registry: Fast::Prometheus.registry, path: "/metrics")
          @app = app
          @registry = registry
          @path = path
        end

        def call(env)
          return @app.call(env) unless env["REQUEST_METHOD"] == "GET" && env["PATH_INFO"] == @path

          body, headers = Exposition.render(
            @registry,
            accept: env["HTTP_ACCEPT"],
            accept_encoding: env["HTTP_ACCEPT_ENCODING"]
          )

          [200, headers, [body]]
        end
      end
    end
  end
end
