# frozen_string_literal: true

require_relative "errors"
require_relative "store"

module Fast
  module Prometheus
    # Metric is the abstract base class for all metric types.
    #
    # Declared label names are normalized to Symbols and label values (and the
    # docstring) to valid UTF-8 here, where they enter the store, so no reader
    # or renderer downstream can meet a mixed encoding or an invalid one.
    #
    # Every metric's per-series storage is a Store, guarded by its own lock.
    # Metrics produced by #with_labels share their parent's Store (and thus
    # its lock), so a mutation on a bound metric and a mutation on its parent
    # are mutually exclusive. Safe to share across OS threads and fibers.
    class Metric
      METRIC_NAME = /\A[a-zA-Z_:][a-zA-Z0-9_:]*\z/
      LABEL_NAME = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

      # The default label set, shared so an unlabeled call allocates nothing.
      NO_LABELS = {}.freeze

      def initialize(name, docstring:, labels: [], preset_labels: {}, store: nil)
        validate_metric_name(name)
        validate_docstring(docstring)
        @name = name.to_s.to_sym
        @docstring = normalize_text(docstring)

        @labels = labels.map { |label| label.to_s.to_sym }.freeze
        validate_label_names(@labels)
        @preset_labels = preset_labels.to_h { |key, value| [key.to_s.to_sym, normalize_text(value).freeze] }
        validate_preset_labels(@labels, @preset_labels)

        @store = store || Store.new

        return unless fully_bound?

        @resolved_key = resolve_internal(@preset_labels)
        seed(@resolved_key)
      end

      attr_reader :name, :docstring, :labels, :preset_labels

      # Returns the current value for the given label set. Scalar types
      # (Counter, Gauge) return 0.0 for unobserved series. Histogram, Summary,
      # and NativeHistogram override this with their own zero-valued shapes.
      def get(labels: NO_LABELS)
        key = resolve(labels)
        store.synchronize { store[key] || 0.0 }
      end

      # Creates the series for +labels+ at its zero value if absent. Never
      # resets a series that already exists. Raises InvalidLabelSet on an
      # unknown or incomplete label set, same as any mutator.
      def init_label_set(labels = NO_LABELS)
        seed(resolve(labels))
      end

      def type
        raise NotImplementedError, "subclasses must implement #type"
      end

      def with_labels(**labels)
        validate_label_keys(labels)
        merged = @preset_labels.merge(labels.transform_values { |v| normalize_text(v).freeze })
        self.class.new(
          @name,
          docstring: @docstring,
          labels: @labels,
          preset_labels: merged,
          store: @store,
          **construction_options
        )
      end

      def values
        series_map { |slot| snapshot_value(slot) }
      end

      # Every series' value in its frozen snapshot shape (see HistogramValue,
      # SummaryValue, NativeHistogramValue; Counter/Gauge use the already-
      # frozen Float), keyed by the series' label values in #labels order,
      # the store's own key. The store is copied and its slots frozen under
      # the lock, so this is a consistent view of every series at one
      # instant that costs one Hash. The seam MetricSnapshot uses.
      def snapshot_values
        store.synchronize { store.to_h.transform_values! { |slot| snapshot_value(slot) } }
      end

      # Runs the block exclusively with respect to every other mutation or read
      # of this metric's store (including on metrics sharing it via
      # #with_labels). Reentrant on the same thread. This is the seam
      # MetricSnapshot uses to build a consistent snapshot of every series.
      def synchronize
        store.synchronize { yield } # rubocop:disable Style/ExplicitBlockArgument
      end

      protected

      attr_reader :store

      # Subclasses override to forward their own configuration (e.g. buckets,
      # schema) through #with_labels. See Histogram, NativeHistogram.
      def construction_options
        {}
      end

      def resolve(labels)
        return @resolved_key if @resolved_key && labels.empty?

        validate_label_keys(labels)

        @labels.map do |n|
          if labels.key?(n)
            normalize_text(labels[n])
          else
            value = @preset_labels[n]
            raise InvalidLabelSet, "missing labels: #{n.inspect}" unless value

            value
          end
        end.freeze
      end

      private

      # Zero value for a fresh series. Counter/Gauge share this Float
      # default; Histogram, Summary, and NativeHistogram override it with
      # their own empty slot.
      def zero_value
        0.0
      end

      # Turns one slot into its frozen snapshot value. Counter/Gauge slots
      # are already-frozen Floats; Histogram, Summary, and NativeHistogram
      # override this to build their own snapshot value type.
      def snapshot_value(slot)
        slot
      end

      # Shared shape behind #values and #snapshot_values: every series'
      # storage transformed by the block, keyed by a fresh frozen label hash,
      # under the lock. yield, not &block: a captured block is a Proc
      # allocation on every call.
      def series_map
        store.synchronize do
          store.to_h.transform_keys { |key| label_hash(key) }.transform_values { |slot| yield slot } # rubocop:disable Style/ExplicitBlockArgument
        end
      end

      # {name => value} for a resolved key, built without the per-pair Arrays
      # Array#zip would make (or the iterator object each_with_index would).
      def label_hash(key)
        hash = {}
        @labels.each_index { |i| hash[@labels[i]] = key[i] }
        hash.freeze
      end

      # Creates the series at +key+ at its zero value if absent. Never resets
      # a series that already exists. Shared by #initialize (auto-seeding a
      # fully-bound metric) and #init_label_set.
      def seed(key)
        store.synchronize { store[key] ||= zero_value }
      end

      def fully_bound?
        @preset_labels.size == @labels.size
      end

      # Label values and docstrings are stored as valid UTF-8 bytes. An
      # ASCII-only String already is one, whatever encoding it is tagged with
      # (US-ASCII from Integer#to_s or Symbol#to_s, BINARY from a Rack env),
      # so it is returned as is: #ascii_only? is coderange-cached, and the hot
      # path allocates nothing per value. Only a non-ASCII String pays for the
      # tag check, and valid UTF-8 is still returned as is — String#scrub
      # would copy.
      def normalize_text(value)
        string = value.is_a?(String) ? value : value.to_s
        return string if string.ascii_only?

        case string.encoding
        when Encoding::UTF_8
          string.valid_encoding? ? string : string.scrub
        when Encoding::BINARY
          # Reinterpreted, never transcoded: BINARY is bytes, not a charset.
          # #scrub! returns self, so the dup is the only object either way.
          string.dup.force_encoding(Encoding::UTF_8).scrub!
        else
          string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        end
      end

      def validate_metric_name(name)
        return if name.to_s.match?(METRIC_NAME)

        raise InvalidMetricName, "invalid metric name: #{name.inspect}"
      end

      def validate_docstring(docstring)
        return if docstring.is_a?(String) && !docstring.empty?

        raise ArgumentError, "docstring must be a non-empty string"
      end

      # Validates the already-normalized Symbol names as a set: each one a
      # legal, unreserved label name, and no two of them the same.
      def validate_label_names(labels)
        labels.each do |label|
          name = label.name
          raise InvalidLabelName, "label name must not start with __: #{label.inspect}" if name.start_with?("__")
          raise InvalidLabelName, "invalid label name: #{label.inspect}" unless name.match?(LABEL_NAME)
        end

        return if labels.uniq.size == labels.size

        raise InvalidLabelName, "duplicate label names: #{labels.inspect}"
      end

      def validate_preset_labels(labels, preset_labels)
        preset_labels.each_key do |key|
          raise InvalidLabelSet, "preset label not in declared labels: #{key.inspect}" unless labels.include?(key)
        end
      end

      def validate_label_keys(labels)
        labels.each_key do |key|
          raise InvalidLabelSet, "unknown label name: #{key.inspect}" unless @labels.include?(key)
        end
      end

      def resolve_internal(merged)
        @labels.map { |n| merged.fetch(n) }.freeze
      end
    end
  end
end
