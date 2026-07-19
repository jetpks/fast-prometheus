# frozen_string_literal: true

require "fast/prometheus"
require "async/http/internet"
require_relative "mapper"

module Fast
  module Prometheus
    module OTLP
      # Exports metrics over HTTP to an OTLP receiver (e.g. Prometheus --web.enable-otlp-receiver).
      class HTTPExporter
        def initialize(endpoint:, registry: Fast::Prometheus.registry, resource_attributes: {}, headers: {})
          @registry = registry
          @url = "#{endpoint}/v1/metrics"
          @headers = [["content-type", "application/x-protobuf"]].concat(
            headers.map { |k, v| [k.to_s, v.to_s] }
          ).tap do |a|
            a.freeze
            a.each(&:freeze)
          end
          @mapper = Mapper.new(resource_attributes: resource_attributes)
          @internet = Async::HTTP::Internet.new
        end

        # Export a snapshot (or collect one from the registry) via HTTP POST.
        # Raises Error on non-2xx responses.
        def export(snapshot = @registry.collect)
          request = @mapper.request(snapshot)

          @internet.post(@url, @headers, request.to_proto) do |response|
            body = response.read
            raise Error, "OTLP export failed: #{response.status} #{body}" unless (200..299).cover?(response.status)
          end
        end

        # Close the underlying HTTP client.
        def close
          @internet.close
        end
      end
    end
  end
end
