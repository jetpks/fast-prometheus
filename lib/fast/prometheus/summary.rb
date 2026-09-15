# frozen_string_literal: true

require_relative "metric"

module Fast
  module Prometheus
    # Summary accumulates observations as sum + count per label set.
    # Unlike the histogram, it provides no quantile computation.
    class Summary < Metric
      # Value holds the accumulated sum and count for a single label set.
      class Value
        attr_accessor :sum, :count

        def initialize
          @sum = 0.0
          @count = 0
        end
      end

      def type
        :summary
      end

      def observe(value, labels: {})
        key = resolve(labels)
        store.synchronize do
          slot = store[key] ||= Value.new
          slot.sum += value
          slot.count += 1
        end
      end

      # {"count" => Integer, "sum" => Float}. Zero-valued for an unobserved series.
      def get(labels: {})
        key = resolve(labels)
        store.synchronize { hash_shape(store[key] || zero_value) }
      end

      def values
        store.synchronize do
          store.to_h.transform_keys { |key| @labels.zip(key).to_h }
               .transform_values { |slot| hash_shape(slot) }
        end
      end

      protected

      def validate_label_names(labels)
        labels.each do |label|
          name = label.to_s
          raise InvalidLabelName, "reserved label name: :quantile" if name == "quantile"
        end

        super
      end

      private

      def zero_value
        Value.new
      end

      def hash_shape(slot)
        { "count" => slot.count, "sum" => slot.sum }
      end
    end
  end
end
