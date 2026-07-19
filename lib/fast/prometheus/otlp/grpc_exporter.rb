# frozen_string_literal: true

require "fast/prometheus"
require "async/grpc"
require "async/http/endpoint"
require "async/http/protocol"
require "protocol/http"
require_relative "mapper"
require_relative "service_interface"

module Fast
  module Prometheus
    module OTLP
      # Pushes metrics over gRPC using socketry/async-grpc.
      class GRPCExporter
        SERVICE_NAME = "opentelemetry.proto.collector.metrics.v1.MetricsService"
        private_constant :SERVICE_NAME

        def initialize(endpoint:, registry: Fast::Prometheus.registry, resource_attributes: {}, headers: {})
          @http_endpoint = Async::HTTP::Endpoint.parse(endpoint, protocol: Async::HTTP::Protocol::HTTP2)
          @registry = registry
          @mapper = Mapper.new(resource_attributes: resource_attributes)
          @http_client = Async::HTTP::Client.new(@http_endpoint)
          grpc_headers = Protocol::HTTP::Headers[headers]
          @grpc_client = Async::GRPC::Client.new(@http_client, headers: grpc_headers)
          @stub = @grpc_client.stub(MetricsServiceInterface, SERVICE_NAME)
        end

        def export(snapshot = @registry.collect)
          @stub.export(@mapper.request(snapshot))
        end

        def close
          @http_client.close
        end
      end
    end
  end
end
