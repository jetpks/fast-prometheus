# frozen_string_literal: true

require "zlib"

require "protocol/http/middleware"
require "fast_prometheus_client/formats/text"
require "fast_prometheus_client/formats/protobuf"

module FastPrometheusClient
  module Middleware
    # Protocol::HTTP middleware that serves metrics at a configurable path.
    # Handles content negotiation (text vs protobuf) and gzip compression.
    class Exporter < Protocol::HTTP::Middleware
      # Formats::Protobuf::CONTENT_TYPE is private_constant, so we define it here.
      PROTOBUF_CONTENT_TYPE =
        "application/vnd.google.protobuf; proto=io.prometheus.client.MetricFamily; encoding=delimited"
      PROTOBUF_ACCEPT = "application/vnd.google.protobuf"

      def initialize(delegate, registry: FastPrometheusClient.registry, path: "/metrics")
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

        if protobuf?(request)
          content_type = PROTOBUF_CONTENT_TYPE
          body = Formats::Protobuf.render(snapshot)
        else
          content_type = Formats::Text::CONTENT_TYPE
          body = Formats::Text.render(snapshot)
        end

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
