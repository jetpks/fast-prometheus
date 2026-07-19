# frozen_string_literal: true

module Fast
  module Prometheus
    class Error < StandardError; end
    class InvalidMetricName < Error; end
    class InvalidLabelName < Error; end
    class InvalidLabelSet < Error; end
    class DuplicateMetric < Error; end
  end
end
