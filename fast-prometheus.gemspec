# frozen_string_literal: true

require_relative "lib/fast/prometheus/version"

Gem::Specification.new do |spec|
  spec.name = "fast-prometheus"
  spec.version = Fast::Prometheus::VERSION

  spec.summary = "A fiber-native Prometheus client for modern Ruby."
  spec.authors = ["Eric Jacobs"]
  spec.license = "MIT"

  spec.homepage = "https://github.com/jetpks/fast-prometheus"

  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir.glob(["{lib}/**/*", "*.md"], File::FNM_DOTMATCH, base: __dir__)

  spec.add_dependency "async", ">= 2.38"
  spec.add_dependency "protocol-http", "~> 0.60"
  spec.add_dependency "async-http"
  spec.add_dependency "async-grpc"
  spec.add_dependency "google-protobuf"
  spec.add_dependency "console"
end
