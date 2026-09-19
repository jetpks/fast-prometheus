# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :test do
  gem "sus"
  gem "sus-fixtures-async"
  gem "sus-fixtures-async-http"
  gem "covered"
  gem "rubocop"
  gem "rack", "~> 3.1"
  # Reference decoder for the exposition and OTLP tests (fixtures/pb); never a runtime dependency.
  gem "google-protobuf", "~> 4.36"
end

group :benchmark do
  gem "benchmark-ips"
  gem "prometheus-client"
end
