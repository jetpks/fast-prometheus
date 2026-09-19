# frozen_string_literal: true

require "fast/prometheus"
require "protocol/grpc/interface"
require_relative "proto"

module Fast
  module Prometheus
    module OTLP
      # Protocol::GRPC::Interface for opentelemetry.proto.collector.metrics.v1.MetricsService.
      class MetricsServiceInterface < Protocol::GRPC::Interface
        rpc :Export,
            request_class: Proto::ExportMetricsServiceRequest,
            response_class: Proto::ExportMetricsServiceResponse
      end
    end
  end
end
