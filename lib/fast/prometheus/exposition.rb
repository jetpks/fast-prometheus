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
    #
    # Both headers are read as RFC 9110 lists over their bytes: comma-separated
    # members, each a token with optional ";"-parameters. The token is matched
    # whole and case-insensitively, parameters other than "q" are ignored, and
    # "q=0" is a refusal. Nothing here raises: a header we cannot make sense of
    # — invalid bytes included — simply scores nothing, which is the text
    # format and no compression.
    module Exposition
      PROTOBUF_ACCEPT = "application/vnd.google.protobuf"
      TEXT_ACCEPT = "text/plain"
      GZIP_CODING = "gzip"

      FORMAT_MAP = {
        true => [Formats::Protobuf, Formats::Protobuf::CONTENT_TYPE],
        false => [Formats::Text, Formats::Text::CONTENT_TYPE]
      }.freeze
      private_constant :FORMAT_MAP

      def self.render(registry, accept:, accept_encoding:)
        format, content_type = FORMAT_MAP[protobuf?(byte_view(accept))]
        body = format.render(registry.collect)
        headers = { "content-type" => content_type }

        if gzip?(byte_view(accept_encoding))
          body = Zlib.gzip(body)
          headers["content-encoding"] = "gzip"
        end

        [body, headers]
      end

      # Protobuf wins when it is acceptable and no less acceptable than text —
      # on a tie, the order Prometheus itself lists the two in.
      private_class_method def self.protobuf?(accept)
        quality = quality_of(accept, PROTOBUF_ACCEPT)
        quality.positive? && quality >= quality_of(accept, TEXT_ACCEPT)
      end

      private_class_method def self.gzip?(accept_encoding)
        quality_of(accept_encoding, GZIP_CODING).positive?
      end

      # The header's bytes, whatever String the server handed us: negotiation
      # answers the bytes and nothing else. #strip and #casecmp? raise on a
      # UTF-8-tagged String holding invalid ones — and io-stream, Puma and a
      # test harness tag the same bytes BINARY, BINARY and UTF-8 — while BINARY
      # bytes are always valid, so nothing below can raise. One String per
      # header on a path that renders the whole registry anyway.
      private_class_method def self.byte_view(header)
        header.to_s.b
      end

      # The highest q value +token+ carries across the members of a list header:
      # 0.0 when it is absent or refused with q=0, 1.0 when it is listed without
      # one. #split with a block keeps a long header's members out of an Array.
      private_class_method def self.quality_of(header, token)
        best = 0.0
        header.split(",") do |member|
          name, _, parameters = member.partition(";")
          next unless name.strip.casecmp?(token)

          quality = quality_parameter(parameters)
          best = quality if quality > best
        end
        best
      end

      # One member's q parameter, 1.0 when it has none. A quoted parameter value
      # holding ";" or "=" can only hide a q from us, never fake one, and a
      # hidden q is the default anyway.
      private_class_method def self.quality_parameter(parameters)
        parameters.split(";") do |parameter|
          name, _, value = parameter.partition("=")
          return value.strip.to_f if name.strip.casecmp?("q")
        end
        1.0
      end
    end
  end
end
