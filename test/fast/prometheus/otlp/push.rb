# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/otlp/push"
require "sus/fixtures/async"

describe Fast::Prometheus::OTLP::Push do
  include Sus::Fixtures::Async::ReactorContext

  describe "basic loop" do
    it "calls exporter.export at least twice" do
      fake_exporter = Object.new
      def fake_exporter.export
        @count ||= 0
        @count += 1
      end

      def fake_exporter.export_count
        @count || 0
      end

      push = Fast::Prometheus::OTLP::Push.new(exporter: fake_exporter, interval: 0.01)
      push.run

      sleep 0.05
      push.stop

      expect(fake_exporter.export_count).to be(:>=, 2)
    end
  end

  describe "error resilience" do
    it "does not kill the loop when exporter raises" do
      fake_exporter = Object.new
      def fake_exporter.export
        @count ||= 0
        @count += 1
        raise StandardError, "boom" if @count == 1
      end

      def fake_exporter.export_count
        @count || 0
      end

      push = Fast::Prometheus::OTLP::Push.new(exporter: fake_exporter, interval: 0.01)
      push.run

      sleep 0.06
      push.stop

      expect(fake_exporter.export_count).to be(:>=, 2)
    end
  end

  describe "#stop" do
    it "stops the loop" do
      fake_exporter = Object.new
      def fake_exporter.export
        @count ||= 0
        @count += 1
      end

      def fake_exporter.export_count
        @count || 0
      end

      push = Fast::Prometheus::OTLP::Push.new(exporter: fake_exporter, interval: 0.01)
      push.run

      sleep 0.04
      count_before = fake_exporter.export_count
      push.stop

      sleep 0.04
      count_after = fake_exporter.export_count

      expect(count_after).to be(:==, count_before)
    end
  end
end
