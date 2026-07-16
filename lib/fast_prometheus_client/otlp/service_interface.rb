# frozen_string_literal: true

require "protocol/grpc/interface"
require_relative "mapper"

module FastPrometheusClient
  module OTLP
    # Protocol::GRPC::Interface for opentelemetry.proto.collector.metrics.v1.MetricsService.
    class MetricsServiceInterface < Protocol::GRPC::Interface
      rpc :Export,
          request_class: Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest,
          response_class: Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceResponse
    end
  end
end
