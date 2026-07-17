# frozen_string_literal: true

require "async"
require "console"

module FastPrometheusClient
  module OTLP
    # Periodically pushes metrics using any exporter that responds to #export.
    class Push
      def initialize(exporter:, interval: 15)
        @exporter = exporter
        @interval = interval
        @task = nil
      end

      # Start the push loop. Returns the Async::Task running it.
      def run(parent: Async::Task.current)
        @task = parent.async do |task|
          task.annotate("OTLP push loop")
          loop do
            sleep(@interval)
            @exporter.export
          rescue StandardError => e
            Console.logger.warn("OTLP push error: #{e}")
          end
        end
      end

      # Stop the push loop.
      def stop
        @task&.stop
        @task = nil
      end
    end
  end
end
