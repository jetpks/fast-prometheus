# frozen_string_literal: true

require_relative "metric"

module Fast
  module Prometheus
    # Histogram samples observations and counts them in configurable buckets.
    # Also provides total count and sum of all observed values.
    #
    # Storage: one slot per label series in the parent @store Hash. Each slot
    # is a HistogramSlot holding sum (Float), count (Integer), and one Integer
    # cell per boundary plus an overflow cell — stored NON-cumulatively.
    class Histogram < Metric
      DEFAULT_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10].freeze

      # Small inner value object holding one series' data.
      class HistogramSlot
        attr_accessor :sum, :count
        attr_reader :cells

        def initialize(buckets:, sum: 0.0, count: 0)
          @buckets = buckets
          @sum = sum
          @count = count
          @cells = [0] * (buckets.size + 1)
        end

        # Cumulative bucket counts, ending with [Float::INFINITY, count].
        def cumulative_buckets
          cumulative = 0
          result = @buckets.each_with_index.map do |boundary, i|
            cumulative += @cells[i]
            [boundary, cumulative]
          end
          cumulative += @cells.last # overflow cell
          result << [Float::INFINITY, cumulative]
        end
      end

      attr_reader :buckets

      def initialize(name, docstring:, labels: [], preset_labels: {}, buckets: DEFAULT_BUCKETS, store: nil)
        raise ArgumentError, "buckets must be a non-empty Array" unless buckets.is_a?(Array) && !buckets.empty?
        raise ArgumentError, "buckets must contain only Numeric values" unless buckets.all? { |b| b.is_a?(Numeric) }
        raise ArgumentError, "buckets must be strictly ascending" unless buckets.each_cons(2).all? { |a, b| a < b }

        raise InvalidLabelName, "label :le is reserved" if labels.include?(:le)

        @buckets = buckets
        super(name, docstring: docstring, labels: labels, preset_labels: preset_labels, store: store)
      end

      def type
        :histogram
      end

      # Record an observation. Finds the first boundary >= value (inclusive le)
      # using bsearch_index. Values above the last boundary go to the overflow cell.
      def observe(value, labels: {})
        key = resolve(labels)
        index = @buckets.bsearch_index { |boundary| boundary >= value } || @buckets.size

        store.synchronize do
          slot = store[key] ||= HistogramSlot.new(buckets: @buckets)

          slot.sum += value
          slot.count += 1
          slot.cells[index] += 1
        end
      end

      # Cumulative bucket counts for a specific series (delegates to slot).
      def cumulative_buckets(labels: {})
        store.synchronize do
          next unless (slot = get(labels: labels))

          slot.cumulative_buckets
        end
      end

      # Get the slot for a label set, or nil if no observations recorded.
      def get(labels: {})
        key = resolve(labels)
        store.synchronize { store[key] }
      end

      # Reader for sum of a specific series.
      def sum(labels: {})
        store.synchronize do
          next unless (slot = get(labels: labels))

          slot.sum
        end
      end

      # Reader for count of a specific series.
      def count(labels: {})
        store.synchronize do
          next unless (slot = get(labels: labels))

          slot.count
        end
      end

      def self.linear_buckets(start:, width:, count:)
        count.times.map { |i| start.to_f + i * width }
      end

      def self.exponential_buckets(start:, factor:, count:)
        raise ArgumentError, "start must be > 0" unless start.positive?
        raise ArgumentError, "factor must be > 1" unless factor > 1
        raise ArgumentError, "count must be >= 1" unless count >= 1

        count.times.map { |i| start.to_f * (factor**i) }
      end

      protected

      def construction_options
        { buckets: @buckets }
      end
    end
  end
end
