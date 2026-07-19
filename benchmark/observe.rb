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
