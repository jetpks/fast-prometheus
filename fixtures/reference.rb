# frozen_string_literal: true

# google-protobuf's view of the schemas this gem encodes (protoc output from
# proto/, checked in under fixtures/pb). Tests decode what the library emits
# with it, so the wire bytes are checked against the reference implementation.
$LOAD_PATH.unshift(File.expand_path("pb", __dir__)) unless $LOAD_PATH.include?(File.expand_path("pb", __dir__))

require "google/protobuf"
require "metrics_pb"
require "opentelemetry/proto/collector/metrics/v1/metrics_service_pb"
