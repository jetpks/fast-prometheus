# frozen_string_literal: true

require "fast/prometheus"

# The documented soft require: fast-completions is a runtime peer, never a
# gemspec dependency of this gem, so an app without it fails loud here — at
# require time, where the missing peer belongs — instead of half-loading a
# sink that can never fire. See docs/how-to/instrument-completions.md.
require "fast/completions/telemetry"

module Fast
  module Prometheus
    module Instrumentation
      # The fast-completions telemetry adapter: one sink object that turns
      # the Telemetry::Sink observation points into five metric families on
      # a registry. Construct it and hand it to Fast::Completions::Client:
      #
      #   sink = Fast::Prometheus::Instrumentation::Completions.new
      #   client = Fast::Completions::Client.new(..., telemetry: [sink])
      #
      # Metric table (frozen):
      #   llm_completions_total           Counter   provider, model, stop_reason
      #   llm_completions_errors_total    Counter   error
      #   llm_completions_duration_seconds Histogram provider, model
      #   llm_completions_ttfb_seconds    Histogram (none)
      #   llm_completions_tokens_total    Counter   provider, model, kind
      #
      # Label values come from the hook arguments and the LIVE assistant
      # Message — provider is message.provider, model is message.model
      # (never response_model/response_id, which are wire metadata, not
      # series identity), stop_reason/error are the hook Symbols, kind is
      # the frozen "input"/"output". The Message contract allows a nil
      # provider or model; those become the "unknown" sentinel so one nil
      # is one series, not a raise.
      #
      # A warm dispatch allocates NOTHING: every hook is chained Hash
      # lookups over existing refs into a pre-bound metric — no label Hash,
      # no Array key, no String is built. A cold series binds once through
      # #with_labels and is cached under the raw hook values, so the miss
      # cost is paid once per (provider, model, stop_reason/kind) triple.
      class Completions
        include Fast::Completions::Telemetry::Sink

        END_LABELS = %i[provider model stop_reason].freeze
        ERROR_LABELS = %i[error].freeze
        DURATION_LABELS = %i[provider model].freeze
        TOKEN_LABELS = %i[provider model kind].freeze

        # nil provider/model collapse here (the Message contract allows
        # both to be nil) rather than minting an exception series.
        UNKNOWN = "unknown"

        COUNTER_TYPES = %i[counter].freeze
        HISTOGRAM_TYPES = %i[histogram].freeze

        private_constant :END_LABELS, :ERROR_LABELS, :DURATION_LABELS, :TOKEN_LABELS,
                         :COUNTER_TYPES, :HISTOGRAM_TYPES

        # +registry+ defaults to the module-level registry, so a second
        # adapter constructed anywhere reuses the same five metrics
        # (Registry#fetch_or_register) and shares their series.
        def initialize(registry: Fast::Prometheus.registry)
          @registry = registry

          # Series caches, one level per label: provider → model →
          # stop_reason/kind (or plain model for the duration histogram)
          # → the bound metric itself. The ttfb histogram is unlabeled and
          # dispatched directly. Keyed by the raw hook values, so a hit is
          # Hash lookups with existing refs and nothing else.
          @ends = {}
          @durations = {}
          @tokens = {}
          @errors = {}

          @completions_total = ensure_counter(:llm_completions_total, END_LABELS,
                                              "Total LLM completions by stop reason")
          @errors_total = ensure_counter(:llm_completions_errors_total, ERROR_LABELS,
                                         "Total LLM completions that raised out of the client")
          @duration_seconds = ensure_histogram(:llm_completions_duration_seconds, DURATION_LABELS,
                                               "LLM completion duration in seconds")
          @ttfb_seconds = ensure_histogram(:llm_completions_ttfb_seconds, [].freeze,
                                           "LLM completion time to first byte in seconds")
          @tokens_total = ensure_counter(:llm_completions_tokens_total, TOKEN_LABELS,
                                         "LLM completion token usage by kind")
        end

        # on_completion_start and on_event stay the Sink's no-ops: the
        # metric table is scoped to ttfb and the two terminal hooks — the
        # per-event surface belongs to whoever reads the Message.

        def on_completion_ttfb(seconds)
          @ttfb_seconds.observe(seconds)
        end

        def on_completion_end(stop_reason, duration, message)
          provider = message.provider
          model = message.model

          # Warm: chained lookups into existing bound metrics. Cold: the
          # bind helpers below run once per series and cache the binding.
          counter = ((@ends[provider] ||= {})[model] ||= {})[stop_reason]
          counter ||= bind_end(provider, model, stop_reason)
          counter.increment

          histogram = (@durations[provider] ||= {})[model]
          histogram ||= bind_duration(provider, model)
          histogram.observe(duration)

          # The Message contract allows nil usage (and the read-only
          # convention says nil-check without allocating): a completion
          # without accounting skips the token counters entirely.
          usage = message.usage
          return unless usage

          kinds = (@tokens[provider] ||= {})[model]
          kinds ||= bind_tokens(provider, model)
          kinds[:input].increment(by: usage.input)
          kinds[:output].increment(by: usage.output)
        end

        # Errored completions get the errors counter and no duration: the
        # histogram observes only completions that returned.
        def on_completion_error(error, _duration)
          counter = @errors[error]
          counter ||= bind_error(error)
          counter.increment
        end

        private

        def ensure_counter(name, labels, docstring)
          metric = @registry.fetch_or_register(name) do
            Counter.new(name, docstring: docstring, labels: labels)
          end

          validate(metric, COUNTER_TYPES, labels)
        end

        def ensure_histogram(name, labels, docstring)
          metric = @registry.fetch_or_register(name) do
            Histogram.new(name, docstring: docstring, labels: labels)
          end

          validate(metric, HISTOGRAM_TYPES, labels)
        end

        # A metric already registered under one of these names is reused
        # only if it is the table's type and declares the table's labels.
        # Otherwise every completion would raise from inside the client's
        # dispatch; raise here instead, once, at construction, where the
        # mistaken declaration is (the RequestMetrics pattern).
        def validate(metric, types, labels)
          unless types.include?(metric.type)
            raise InvalidMetricType, "#{metric.name} declares type #{metric.type.inspect}, not #{types.inspect}"
          end

          unless metric.labels == labels
            raise InvalidLabelSet, "#{metric.name} declares labels #{metric.labels.inspect}, not #{labels.inspect}"
          end

          metric
        end

        def bind_end(provider, model, stop_reason)
          @ends[provider][model][stop_reason] = @completions_total.with_labels(
            provider: label_value(provider), model: label_value(model), stop_reason: stop_reason
          )
        end

        def bind_duration(provider, model)
          @durations[provider][model] = @duration_seconds.with_labels(
            provider: label_value(provider), model: label_value(model)
          )
        end

        def bind_tokens(provider, model)
          kinds = @tokens[provider][model] = {}
          kinds[:input] = @tokens_total.with_labels(
            provider: label_value(provider), model: label_value(model), kind: "input"
          )
          kinds[:output] = @tokens_total.with_labels(
            provider: label_value(provider), model: label_value(model), kind: "output"
          )
          kinds
        end

        def bind_error(error)
          @errors[error] = @errors_total.with_labels(error: error)
        end

        # with_labels normalizes label values to frozen UTF-8 Strings, so
        # passing the hook Symbol binds its to_s and passing a String
        # binds the ref — nothing here runs on a warm dispatch.
        def label_value(value)
          value || UNKNOWN
        end
      end
    end
  end
end
