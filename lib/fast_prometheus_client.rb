# frozen_string_literal: true

require_relative "fast_prometheus_client/version"

Dir.glob("#{__dir__}/fast_prometheus_client/**/*.rb").sort.each do |file|
  require file
end

module FastPrometheusClient
end
