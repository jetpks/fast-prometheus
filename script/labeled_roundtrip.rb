#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone check: build a registry with one LABELED series per metric type,
# render via Protobuf, decode every length-delimited frame, assert LabelPairs
# match what was registered.

require "fast/prometheus"
require "fast/prometheus/formats/protobuf"

registry = Fast::Prometheus::Registry.new

# Labeled counter
counter = registry.counter(:labeled_counter_total, docstring: "a labeled counter", labels: [:job])
counter.increment(by: 10, labels: { job: "scrape" })

# Labeled gauge
gauge = registry.gauge(:labeled_gauge, docstring: "a labeled gauge", labels: [:host])
gauge.set(42.0, labels: { host: "web-1" })

# Labeled summary
summary = registry.summary(:labeled_summary_seconds, docstring: "a labeled summary", labels: [:endpoint])
summary.observe(1.5, labels: { endpoint: "/api" })

# Labeled classic histogram
histogram = registry.histogram(:labeled_histogram_seconds, docstring: "a labeled histogram", labels: [:path])
histogram.observe(0.5, labels: { path: "/health" })

# Labeled native histogram
nh = registry.native_histogram(:labeled_nh_seconds, docstring: "a labeled native histogram", labels: [:service])
nh.observe(0.1, labels: { service: "auth" })

# Render via protobuf
snapshot = registry.collect
bin = Fast::Prometheus::Formats::Protobuf.render(snapshot)

# Split into length-delimited frames
def split_frames(bin)
  frames = []
  i = 0
  while i < bin.bytesize
    len = 0
    shift = 0
    loop do
      b = bin.getbyte(i)
      len |= (b & 0x7f) << shift
      shift += 7
      i += 1
      break if b < 0x80
    end
    frames << bin.byteslice(i, len)
    i += len
  end
  frames
end

frames = split_frames(bin)
expect_names = %w[
  labeled_counter_total
  labeled_gauge
  labeled_summary_seconds
  labeled_histogram_seconds
  labeled_nh_seconds
]
expect_label_sets = [
  [{ name: "job", value: "scrape" }],
  [{ name: "host", value: "web-1" }],
  [{ name: "endpoint", value: "/api" }],
  [{ name: "path", value: "/health" }],
  [{ name: "service", value: "auth" }]
]

if frames.size != expect_names.size
  puts "ERROR: expected #{expect_names.size} frames, got #{frames.size}"
  exit 1
end

frames.each_with_index do |frame, idx|
  mf = Fast::Prometheus::Formats::Protobuf::Proto::MetricFamily.decode(frame)

  if mf.name != expect_names[idx]
    puts "ERROR: frame #{idx}: expected name #{expect_names[idx]}, got #{mf.name}"
    exit 1
  end

  metric = mf.metric.first
  actual_labels = metric.label.to_a.map { |lp| { name: lp.name, value: lp.value } }
  expected = expect_label_sets[idx]

  if actual_labels != expected
    puts "ERROR: frame #{idx} (#{mf.name}): expected labels #{expected.inspect}, got #{actual_labels.inspect}"
    exit 1
  end
end

puts "LABELED_OK"
exit 0
