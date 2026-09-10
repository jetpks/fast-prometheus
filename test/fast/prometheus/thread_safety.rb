# frozen_string_literal: true

require "fast/prometheus"
require "async"

describe "Fast::Prometheus thread safety" do
  let(:registry) { Fast::Prometheus::Registry.new }

  it "loses no updates, raises nothing, and keeps snapshots consistent across threads" do
    threads_count = 4
    ops = 500
    series_every = ops / 10

    counter = registry.counter(:requests_total, docstring: "requests", labels: [:series])
    gauge = registry.gauge(:inflight, docstring: "inflight", labels: [:series])
    histogram = registry.histogram(:duration_seconds, docstring: "duration", labels: [:series])
    summary = registry.summary(:latency_seconds, docstring: "latency", labels: [:series])
    native = registry.native_histogram(:native_seconds, docstring: "native", labels: [:series])
    hot = registry.counter(:hot_total, docstring: "hot")
    bound = hot.with_labels

    errors = []
    errors_lock = Mutex.new
    record_error = ->(e) { errors_lock.synchronize { errors << e } }

    done = false
    torn = []
    scraper = Thread.new do
      until done
        snapshot = registry.collect
        snapshot.metrics.each do |metric_snapshot|
          metric_snapshot.series.each do |series|
            value = series.value
            case metric_snapshot.type
            when :histogram
              torn << "histogram" if value.cumulative_buckets.last.last != value.count
            when :native_histogram
              buckets = value.positive_buckets.sum { |_, c| c } + value.negative_buckets.sum { |_, c| c }
              torn << "native_histogram" if buckets + value.zero_count != value.count
            end
          end
        end
      end
    rescue StandardError => e
      record_error.call(e)
    end

    writers = threads_count.times.map do |t|
      Thread.new do
        Sync do
          ops.times do |i|
            series = "s#{i / series_every}"
            counter.increment(labels: { series: series })
            gauge.increment(labels: { series: series })
            histogram.observe(0.25, labels: { series: series })
            summary.observe(1.0, labels: { series: series })
            native.observe(1.5, labels: { series: series })
            t.even? ? hot.increment : bound.increment
          end
        end
      rescue StandardError => e
        record_error.call(e)
      end
    end

    writers.each(&:join)
    done = true
    scraper.join

    expect(errors).to be(:==, [])
    expect(torn).to be(:==, [])

    expected = threads_count * ops
    expect(counter.values.values.sum).to be(:==, expected)
    expect(gauge.values.values.sum).to be(:==, expected)
    expect(histogram.values.values.sum(&:count)).to be(:==, expected)
    expect(summary.values.values.sum(&:count)).to be(:==, expected)
    expect(native.values.values.sum(&:count)).to be(:==, expected)
    expect(hot.get).to be(:==, expected)

    histogram.values.each_value do |slot|
      expect(slot.cells.sum).to be(:==, slot.count)
    end
    native.values.each_value do |slot|
      expect(slot.positive.values.sum + slot.negative.values.sum + slot.zero_count).to be(:==, slot.count)
    end
  end

  it "registers distinct names concurrently without corrupting the registry" do
    names = 20.times.map { |i| :"metric_#{i}" }

    threads = names.map do |name|
      Thread.new { registry.counter(name, docstring: "d") }
    end
    threads.each(&:join)

    expect(registry.metrics.map(&:name).sort).to be(:==, names.sort)
  end
end
