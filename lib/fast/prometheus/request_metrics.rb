# frozen_string_literal: true

require "fast/prometheus"

module Fast
  module Prometheus
    # Owns the RED metrics (request count + duration) recorded for every HTTP
    # request. Shared by Middleware::Instrumentation and Rack::Instrumentation
    # so registration and recording exist exactly once.
    #
    # The method label is allowlisted, so the two metrics hold at most ten
    # method values however many tokens clients invent — nothing reclaims a
    # series once it exists.
    class RequestMetrics
      LABELS = %i[method status].freeze

      # The RFC 9110 methods plus PATCH, each mapped to the frozen String the
      # store keeps, so an allowlisted method costs a lookup and no object.
      # Matching is case-sensitive (RFC 9110 section 9.1) and finds a
      # BINARY-tagged token from a Rack env: ASCII-only Strings hash and
      # compare equal whatever their encoding tag.
      METHODS = %w[GET HEAD POST PUT DELETE CONNECT OPTIONS TRACE PATCH].to_h { |name| [name, name] }.freeze

      # What every other token is counted as, the value OpenTelemetry's HTTP
      # semantic conventions collapse an unrecognized method to.
      OTHER_METHOD = "_OTHER"

      private_constant :LABELS, :METHODS, :OTHER_METHOD

      def initialize(registry:, native: false, prefix: "http_server")
        @registry = registry
        @counter = validate_labels(ensure_counter(prefix))
        @histogram = validate_labels(ensure_histogram(prefix, native))
      end

      def record(method, status, started_at)
        labels = { method: METHODS[method] || OTHER_METHOD, status: status }
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        @counter.increment(labels: labels)
        @histogram.observe(duration, labels: labels)
      end

      private

      def ensure_counter(prefix)
        name = :"#{prefix}_requests_total"
        @registry.fetch_or_register(name) do
          Counter.new(name, docstring: "Total HTTP requests", labels: LABELS)
        end
      end

      def ensure_histogram(prefix, native)
        name = :"#{prefix}_request_duration_seconds"
        @registry.fetch_or_register(name) do
          if native
            NativeHistogram.new(name, docstring: "HTTP request duration in seconds", labels: LABELS)
          else
            Histogram.new(name, docstring: "HTTP request duration in seconds", labels: LABELS)
          end
        end
      end

      # A metric already registered under one of these names is reused only if
      # it declares this label set. Otherwise every request would raise
      # InvalidLabelSet from inside the app's request path; raise here instead,
      # once, where the mistaken declaration is.
      def validate_labels(metric)
        return metric if metric.labels == LABELS

        raise InvalidLabelSet, "#{metric.name} declares labels #{metric.labels.inspect}, not #{LABELS.inspect}"
      end
    end
  end
end
