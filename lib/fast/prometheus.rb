# frozen_string_literal: true

require_relative "prometheus/version"
require_relative "prometheus/errors"
require_relative "prometheus/metric"
require_relative "prometheus/counter"
require_relative "prometheus/gauge"
require_relative "prometheus/histogram"
require_relative "prometheus/summary"
require_relative "prometheus/native_histogram"
require_relative "prometheus/registry"
require_relative "prometheus/snapshot"

module Fast
  module Prometheus
  end
end
