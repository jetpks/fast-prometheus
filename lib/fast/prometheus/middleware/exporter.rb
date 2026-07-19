# frozen_string_literal: true

require "zlib"

require "fast/prometheus"
require "protocol/http/middleware"
require "fast/prometheus/formats/text"
require "fast/prometheus/formats/protobuf"

module Fast
  module Prometheus
    module Middleware
      # Protocol::HTTP middleware that serves metrics at a configurable path.
      # Handles content negotiation (text vs protobuf) and gzip compression.
      class Exporter < Protocol::HTTP::Middleware
        PROTOBUF_ACCEPT = "application/vnd.google.protobuf"

        FORMAT_MAP = {
          true => [Formats::Protobuf, Formats::Protobuf::CONTENT_TYPE],
          false => [Formats::Text, Formats::Text::CONTENT_TYPE]
        }.freeze
        private_constant :FORMAT_MAP

        def initialize(delegate, registry: Fast::Prometheus.registry, path: "/metrics")
          super(delegate)
          @registry = registry
          @path = path
        end

        def call(request)
          return serve_metrics(request) if request.method == "GET" && request.path == @path

          super
        end

        def serve_metrics(request)
          snapshot = @registry.collect
          format, content_type = FORMAT_MAP[protobuf?(request)]
          body = format.render(snapshot)

          if gzip?(request)
            body = Zlib.gzip(body)
            headers = Protocol::HTTP::Headers[
              "content-type" => content_type,
              "content-encoding" => "gzip"
            ]
          else
            headers = Protocol::HTTP::Headers["content-type" => content_type]
          end

          Protocol::HTTP::Response[200, headers, [body]]
        end

        def protobuf?(request)
          accept = request.headers["accept"]
          return false unless accept

          accept.to_s.include?(PROTOBUF_ACCEPT)
        end

        def gzip?(request)
          encoding = request.headers["accept-encoding"]
          return false unless encoding

          encoding.to_s.include?("gzip")
        end
      end
    end
  end
end
