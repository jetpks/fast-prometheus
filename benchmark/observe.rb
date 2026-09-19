# frozen_string_literal: true

# Observation benchmark: every mutation and read a metric offers, run against
# prometheus-client's equivalent where it has one, reported as one table with
# the two libraries side by side: iterations per second (benchmark-ips) and
# Ruby objects allocated per call (GC.stat, exact). Label Hashes are built
# once outside the loops, so the allocation count is the library's, not the
# caller's literal.
#
#   bundle exec ruby benchmark/observe.rb
#   BENCH_QUICK=1 bundle exec ruby benchmark/observe.rb

require "benchmark/ips"
require "prometheus/client"
require_relative "../lib/fast/prometheus"

quick = ENV["BENCH_QUICK"]

LABELS = { method: "GET", status: "200" }.freeze
METHOD_LABEL = { method: "GET" }.freeze

fast = {
  counter: Fast::Prometheus::Counter.new(:requests_total, docstring: "requests", labels: %i[method status]),
  gauge: Fast::Prometheus::Gauge.new(:inflight, docstring: "inflight", labels: %i[method status]),
  histogram: Fast::Prometheus::Histogram.new(:seconds, docstring: "duration", labels: [:method]),
  summary: Fast::Prometheus::Summary.new(:bytes, docstring: "size", labels: [:method]),
  native: Fast::Prometheus::NativeHistogram.new(:native_seconds, docstring: "duration", labels: [:method])
}
client = {
  counter: Prometheus::Client::Counter.new(:requests_total, docstring: "requests", labels: %i[method status]),
  gauge: Prometheus::Client::Gauge.new(:inflight, docstring: "inflight", labels: %i[method status]),
  histogram: Prometheus::Client::Histogram.new(:seconds, docstring: "duration", labels: [:method]),
  summary: Prometheus::Client::Summary.new(:bytes, docstring: "size", labels: [:method])
}
# Bound metrics are resolved once and held for the loop, the way an
# instrumented hot path holds them.
fast_bound = { counter: fast[:counter].with_labels(**LABELS), gauge: fast[:gauge].with_labels(**LABELS),
               histogram: fast[:histogram].with_labels(**METHOD_LABEL),
               native: fast[:native].with_labels(**METHOD_LABEL) }
client_bound = { counter: client[:counter].with_labels(**LABELS), gauge: client[:gauge].with_labels(**LABELS),
                 histogram: client[:histogram].with_labels(**METHOD_LABEL) }

# operation => [fast call, prometheus-client call or nil]
OPERATIONS = {
  "counter increment, labels" => [-> { fast[:counter].increment(labels: LABELS) },
                                  -> { client[:counter].increment(labels: LABELS) }],
  "counter increment, bound" => [-> { fast_bound[:counter].increment },
                                 -> { client_bound[:counter].increment }],
  "counter get, labels" => [-> { fast[:counter].get(labels: LABELS) },
                            -> { client[:counter].get(labels: LABELS) }],
  "gauge set, labels" => [-> { fast[:gauge].set(3, labels: LABELS) },
                          -> { client[:gauge].set(3, labels: LABELS) }],
  "gauge set, bound" => [-> { fast_bound[:gauge].set(3) },
                         -> { client_bound[:gauge].set(3) }],
  "gauge increment, labels" => [-> { fast[:gauge].increment(labels: LABELS) },
                                -> { client[:gauge].increment(labels: LABELS) }],
  "histogram observe, labels" => [-> { fast[:histogram].observe(0.042, labels: METHOD_LABEL) },
                                  -> { client[:histogram].observe(0.042, labels: METHOD_LABEL) }],
  "histogram observe, bound" => [-> { fast_bound[:histogram].observe(0.042) },
                                 -> { client_bound[:histogram].observe(0.042) }],
  "summary observe, labels" => [-> { fast[:summary].observe(512, labels: METHOD_LABEL) },
                                -> { client[:summary].observe(512, labels: METHOD_LABEL) }],
  "native histogram observe, labels" => [-> { fast[:native].observe(0.042, labels: METHOD_LABEL) }, nil],
  "native histogram observe, bound" => [-> { fast_bound[:native].observe(0.042) }, nil]
}.freeze

def objects_per_call(call, times = 10_000)
  call.call
  GC.start
  before = GC.stat(:total_allocated_objects)
  times.times { call.call }
  (GC.stat(:total_allocated_objects) - before) / times.to_f
end

report = Benchmark.ips do |x|
  x.quiet = true
  x.config(time: quick ? 0.5 : 2, warmup: quick ? 0.2 : 1)
  OPERATIONS.each do |name, (fast_call, client_call)|
    x.report("#{name} fast", &fast_call)
    x.report("#{name} client", &client_call) if client_call
  end
end
ips = report.entries.to_h { |entry| [entry.label, entry.ips] }

def millions(value)
  value ? "#{(value / 1e6).round(2)}M" : "—"
end

def ratio(fast, client)
  client ? "#{(fast / client).round(2)}x" : "—"
end

puts "#{RUBY_DESCRIPTION}; prometheus-client #{Gem.loaded_specs['prometheus-client'].version}"
puts
columns = ["operation", "fast-prometheus i/s", "prometheus-client i/s", "fast / client",
           "fast-prometheus objects/call", "prometheus-client objects/call"]
puts "| #{columns.join(' | ')} |"
puts "|#{'---|' * columns.size}"
OPERATIONS.each do |name, (fast_call, client_call)|
  fast_ips = ips["#{name} fast"]
  client_ips = ips["#{name} client"]
  cells = [name, millions(fast_ips), millions(client_ips), ratio(fast_ips, client_ips),
           objects_per_call(fast_call).round(2), client_call ? objects_per_call(client_call).round(2) : "—"]
  puts "| #{cells.join(' | ')} |"
end
