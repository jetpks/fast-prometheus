# frozen_string_literal: true

require_relative "metric"

module FastPrometheusClient
  # SummaryValue holds the accumulated sum and count for a single label set.
  class SummaryValue
    attr_reader :sum, :count

    def initialize
      @sum = 0.0
      @count = 0
    end
  end

  # Summary accumulates observations as sum + count per label set.
  # Unlike the histogram, it provides no quantile computation.
  class Summary < Metric
    def type
      :summary
    end

    def observe(value, labels: {})
      key = resolve(labels)
      slot = store[key] || SummaryValue.new
      slot.instance_variable_set(:@sum, slot.sum + value)
      slot.instance_variable_set(:@count, slot.count + 1)
      store[key] = slot
    end

    def get(labels: {})
      store[resolve(labels)]
    end

    protected

    def validate_label_names(labels)
      labels.each do |label|
        name = label.to_s
        raise InvalidLabelName, "reserved label name: :quantile" if name == "quantile"
      end

      super
    end
  end
end
