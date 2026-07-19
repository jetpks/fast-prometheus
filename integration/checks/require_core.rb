# frozen_string_literal: true

require "fast/prometheus"

FORBIDDEN = [
  %r{async/http},
  %r{async/grpc},
  %r{google/protobuf},
  %r{(?:^|/)grpc(?:\.rb)?$}
].freeze

leaked = $LOADED_FEATURES.select { |f| FORBIDDEN.any? { |pattern| f =~ pattern } }

if leaked.empty?
  puts "CHECK core-require-io-free: PASS"
else
  puts "CHECK core-require-io-free: FAIL leaked features: #{leaked.join(', ')}"
end
