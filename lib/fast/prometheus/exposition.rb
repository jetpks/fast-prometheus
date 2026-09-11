# frozen_string_literal: true

require "zlib"

require "fast/prometheus"
require "fast/prometheus/formats/text"
require "fast/prometheus/formats/protobuf"

module Fast
  module Prometheus
    # Renders a registry snapshot into an exposition body and response headers,
    # negotiating format (text vs protobuf) and gzip from Accept / Accept-Encoding
    # header values. Shared by Middleware::Exporter and Rack::Exporter so
    # negotiation and compression exist exactly once.
    module Exposition
      PROTOBUF_ACCEPT = "application/vnd.google.protobuf"

      FORMAT_MAP = {
        true => [Formats::Protobuf, Formats::Protobuf::CONTENT_TYPE],
        false => [Formats::Text, Formats::Text::CONTENT_TYPE]
      }.freeze
      private_constant :FORMAT_MAP

      def self.render(registry, accept:, accept_encoding:)
        format, content_type = FORMAT_MAP[protobuf?(accept)]
        body = format.render(registry.collect)
        headers = { "content-type" => content_type }

        if gzip?(accept_encoding)
          body = Zlib.gzip(body)
          headers["content-encoding"] = "gzip"
        end

        [body, headers]
      end

      private_class_method def self.protobuf?(accept)
        accept.to_s.include?(PROTOBUF_ACCEPT)
      end

      private_class_method def self.gzip?(accept_encoding)
        accept_encoding.to_s.include?("gzip")
      end
    end
  end
end
