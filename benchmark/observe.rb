# frozen_string_literal: true

require "benchmark/ips"
require "prometheus/client"
require_relative "../lib/fast/prometheus"

quick = ENV["BENCH_QUICK"]

# ── Counter: labeled increment (labels resolved per call) ────────────────────

fast_counter = Fast::Prometheus::Counter.new(
  :requests_total,
  docstring: "HTTP requests",
  labels: %i[method status]
)

pc_counter = Prometheus::Client::Counter.new(
  :requests_total,
  docstring: "HTTP requests",
  labels: %i[method status]
)

# ── Counter: bound fast-path (with_labels held outside loop) ─────────────────

fast_bound = fast_counter.with_labels(method: "GET", status: "200")
pc_bound = pc_counter.with_labels(method: "GET", status: "200")

# ── Histogram: classic observe (labels resolved per call) ────────────────────

fast_histogram = Fast::Prometheus::Histogram.new(
  :request_duration_seconds,
  docstring: "Request duration",
  labels: [:method]
)

pc_histogram = Prometheus::Client::Histogram.new(
  :request_duration_seconds,
  docstring: "Request duration",
  labels: [:method]
)

# ── Native histogram (fast-prometheus-client only) ──────────────────────────

fast_native = Fast::Prometheus::NativeHistogram.new(
  :request_duration_seconds,
  docstring: "Request duration",
  labels: [:method]
)

# ── Run benchmarks ──────────────────────────────────────────────────────────

Benchmark.ips do |x|
  x.config(time: quick ? 0.5 : 2, warmup: quick ? 0.2 : 1)

  x.report("counter labels (fast)") do |times|
    i = 0
    while i < times
      fast_counter.increment(labels: { method: "GET", status: "200" })
      i += 1
    end
  end

  x.report("counter labels (prometheus-client)") do |times|
    i = 0
    while i < times
      pc_counter.increment(labels: { method: "GET", status: "200" })
      i += 1
    end
  end

  x.report("counter bound (fast)") do |times|
    i = 0
    while i < times
      fast_bound.increment
      i += 1
    end
  end

  x.report("counter bound (prometheus-client)") do |times|
    i = 0
    while i < times
      pc_bound.increment
      i += 1
    end
  end

  x.report("histogram observe (fast)") do |times|
    i = 0
    while i < times
      fast_histogram.observe(0.042, labels: { method: "GET" })
      i += 1
    end
  end

  x.report("histogram observe (prometheus-client)") do |times|
    i = 0
    while i < times
      pc_histogram.observe(0.042, labels: { method: "GET" })
      i += 1
    end
  end

  x.report("native histogram observe (fast)") do |times|
    i = 0
    while i < times
      fast_native.observe(0.042, labels: { method: "GET" })
      i += 1
    end
  end

  x.compare!
end

# ── Allocations per operation ──────────────────────────────────────────────
#
# Ruby objects allocated by one call, averaged over a batch (GC.stat is
# exact). The labels Hash is built once outside the batch, so the count is
# what the library allocates, not the caller's literal.

def objects_per_call(call, times = 10_000)
  GC.start
  before = GC.stat(:total_allocated_objects)
  times.times { call.call }
  (GC.stat(:total_allocated_objects) - before) / times.to_f
end

labels = { method: "GET", status: "200" }.freeze
method_label = { method: "GET" }.freeze

puts
puts "Allocations per call (objects):"
{
  "counter labels (fast)" => -> { fast_counter.increment(labels: labels) },
  "counter labels (prometheus-client)" => -> { pc_counter.increment(labels: labels) },
  "counter bound (fast)" => -> { fast_bound.increment },
  "counter bound (prometheus-client)" => -> { pc_bound.increment },
  "histogram observe (fast)" => -> { fast_histogram.observe(0.042, labels: method_label) },
  "histogram observe (prometheus-client)" => -> { pc_histogram.observe(0.042, labels: method_label) },
  "native histogram observe (fast)" => -> { fast_native.observe(0.042, labels: method_label) }
}.each do |name, call|
  call.call
  puts "  #{name.ljust(40)} #{objects_per_call(call).round(2)}"
end
