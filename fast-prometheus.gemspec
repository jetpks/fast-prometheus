# frozen_string_literal: true

require_relative "lib/fast/prometheus/version"

Gem::Specification.new do |spec|
  spec.name = "fast-prometheus"
  spec.version = Fast::Prometheus::VERSION

  spec.summary = "A fiber-native Prometheus client for modern Ruby."
  spec.authors = ["Eric Jacobs"]
  spec.license = "MIT"

  spec.homepage = "https://github.com/jetpks/fast-prometheus"

  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir.glob(["{lib}/**/*", "*.md"], File::FNM_DOTMATCH, base: __dir__)

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/jetpks/fast-prometheus"
  spec.metadata["changelog_uri"] = "https://github.com/jetpks/fast-prometheus/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "async", ">= 2.38"
  spec.add_dependency "protocol-http", "~> 0.60"
  spec.add_dependency "async-http", "~> 0.95"
  spec.add_dependency "async-grpc", "~> 0.7"
  spec.add_dependency "google-protobuf", "~> 4.35"
  spec.add_dependency "console", "~> 1.37"
end
