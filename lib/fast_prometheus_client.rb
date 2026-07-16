# frozen_string_literal: true

require_relative "fast_prometheus_client/version"

# A fiber-native Prometheus client for modern Ruby. Built on the socketry/async
# ecosystem: zero-lock hot path under cooperative scheduling, native histograms
# as a first-class metric type, protobuf scrape exposition, and OTLP export over
# gRPC (async-grpc) and HTTP.
module FastPrometheusClient
end
