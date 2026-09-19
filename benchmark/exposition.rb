# frozen_string_literal: true

# Exposition benchmark: what one scrape of a large registry costs to render,
# in time and in allocation, for fast-prometheus's text and protobuf
# renderers against the two shapes of google-protobuf encoder this gem
# shipped before fast-protowire (whole family in one message, as 0.2.0 did;
# one Metric at a time, as the streamed fix did) and prometheus-client's
# text formatter over an equivalent registry.
#
#   bundle exec ruby benchmark/exposition.rb            # 36,000 series x 12 labels
#   SERIES=5000 bundle exec ruby benchmark/exposition.rb
#   BENCH_QUICK=1 bundle exec ruby benchmark/exposition.rb
#
# Allocation columns are taken with GC disabled around one render, so they
# are the render's whole footprint: Ruby objects (GC.stat), bytes malloc'd
# for their payloads and for google-protobuf's native arenas, and the
# google-protobuf messages (one arena each) still alive afterwards. GC
# columns are over the timed renders with GC enabled.

require "objspace"
require "prometheus/client"
require "prometheus/client/formats/text"
require_relative "../lib/fast/prometheus"
require_relative "../lib/fast/prometheus/formats/text"
require_relative "../lib/fast/prometheus/formats/protobuf"

$LOAD_PATH.unshift(File.expand_path("../fixtures", __dir__))
require "reference"

quick = ENV["BENCH_QUICK"]
SERIES = Integer(ENV.fetch("SERIES", quick ? 5_000 : 36_000))
LABELS = 12
RENDERS = quick ? 3 : 10
LABEL_NAMES = Array.new(LABELS) { |i| :"label_#{i}" }

def label_set(index)
  LABEL_NAMES.to_h { |name| [name, "#{name}-#{index}".ljust(12, "x")] }
end

# A registry shaped like production: one wide counter carrying the series
# count, plus a labeled histogram, gauge and summary.
fast = Fast::Prometheus::Registry.new
wide = fast.counter(:wide_events_total, docstring: "wide labeled counter", labels: LABEL_NAMES)
SERIES.times { |i| wide.increment(labels: label_set(i)) }
histogram = fast.histogram(:request_seconds, docstring: "request latency", labels: [:path])
gauge = fast.gauge(:temperature, docstring: "gauge", labels: [:room])
summary = fast.summary(:payload_bytes, docstring: "summary", labels: [:kind])
20.times do |n|
  histogram.observe(n * 0.01, labels: { path: "/p#{n}" })
  gauge.set(n, labels: { room: "r#{n}" })
  summary.observe(n, labels: { kind: "k#{n}" })
end
snapshot = fast.collect

client = Prometheus::Client::Registry.new
client_wide = client.counter(:wide_events_total, docstring: "wide labeled counter", labels: LABEL_NAMES)
SERIES.times { |i| client_wide.increment(labels: label_set(i)) }
client_histogram = client.histogram(:request_seconds, docstring: "request latency", labels: [:path])
client_gauge = client.gauge(:temperature, docstring: "gauge", labels: [:room])
client_summary = client.summary(:payload_bytes, docstring: "summary", labels: [:kind])
20.times do |n|
  client_histogram.observe(n * 0.01, labels: { path: "/p#{n}" })
  client_gauge.set(n, labels: { room: "r#{n}" })
  client_summary.observe(n, labels: { kind: "k#{n}" })
end

# The google-protobuf encoders fast-prometheus used before fast-protowire,
# over the same snapshot and the protoc-generated classes under fixtures/pb.
module GoogleProtobuf
  PB = Io::Prometheus::Client
  TYPES = { counter: :COUNTER, gauge: :GAUGE, summary: :SUMMARY, histogram: :HISTOGRAM }.freeze
  METRIC_TAG = Fast::Protowire::Wire.tag(4, Fast::Protowire::Wire::LENGTH_DELIMITED)

  # 0.2.0: every series as a message inside one MetricFamily, encoded once.
  def self.whole_family(snapshot)
    snapshot.metrics.each_with_object(String.new) do |ms, out|
      metrics = ms.series.map { |values, value| metric(ms.label_names, values, value, ms.type) }
      family = PB::MetricFamily.new(name: ms.name.to_s, help: ms.docstring, type: TYPES.fetch(ms.type), metric: metrics)
      frame = PB::MetricFamily.encode(family)
      Fast::Protowire::Wire.append_varint(out, frame.bytesize)
      out << frame
    end
  end

  # The streamed fix: header, then one Metric encoded and appended at a time.
  def self.per_series(snapshot)
    snapshot.metrics.each_with_object(String.new) do |ms, out|
      header = PB::MetricFamily.new(name: ms.name.to_s, help: ms.docstring, type: TYPES.fetch(ms.type))
      frame = ms.series.each_with_object(PB::MetricFamily.encode(header)) do |(values, value), buffer|
        encoded = PB::Metric.encode(metric(ms.label_names, values, value, ms.type))
        Fast::Protowire::Wire.append_length_delimited(buffer, METRIC_TAG, encoded)
      end
      Fast::Protowire::Wire.append_varint(out, frame.bytesize)
      out << frame
    end
  end

  def self.metric(names, values, value, type)
    labels = names.zip(values).map { |name, label_value| PB::LabelPair.new(name: name.to_s, value: label_value) }
    case type
    when :counter then PB::Metric.new(label: labels, counter: PB::Counter.new(value: value))
    when :gauge then PB::Metric.new(label: labels, gauge: PB::Gauge.new(value: value))
    when :summary
      PB::Metric.new(label: labels, summary: PB::Summary.new(sample_count: value.count, sample_sum: value.sum))
    when :histogram
      buckets = value.cumulative_buckets.map { |bound, count| PB::Bucket.new(upper_bound: bound, cumulative_count: count) }
      PB::Metric.new(label: labels,
                     histogram: PB::Histogram.new(sample_count: value.count, sample_sum: value.sum, bucket: buckets))
    end
  end
end

RENDERERS = {
  "fast-prometheus text" => -> { Fast::Prometheus::Formats::Text.render(snapshot) },
  "fast-prometheus protobuf (fast-protowire)" => -> { Fast::Prometheus::Formats::Protobuf.render(snapshot) },
  "google-protobuf, one Metric at a time" => -> { GoogleProtobuf.per_series(snapshot) },
  "google-protobuf, whole family (0.2.0)" => -> { GoogleProtobuf.whole_family(snapshot) },
  "prometheus-client text" => -> { Prometheus::Client::Formats::Text.marshal(client) }
}.freeze

def arenas
  ObjectSpace.each_object(Google::Protobuf::Internal::Arena).count
end

# One render with GC off: everything it allocated is still there to count.
def footprint(render)
  GC.start
  GC.disable
  objects = GC.stat(:total_allocated_objects)
  malloc = GC.stat(:malloc_increase_bytes)
  output = render.call
  result = {
    bytes: output.bytesize,
    objects: GC.stat(:total_allocated_objects) - objects,
    malloc_mib: (GC.stat(:malloc_increase_bytes) - malloc) / 1024.0 / 1024,
    arenas: arenas
  }
  GC.enable
  GC.start
  result
end

# Timed renders with GC on: what the process pays per scrape.
def timed(render, count)
  render.call
  GC.start
  minor = GC.stat(:minor_gc_count)
  major = GC.stat(:major_gc_count)
  gc_ms = GC.stat(:time)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  count.times { render.call }
  seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  { seconds: seconds / count, minor: GC.stat(:minor_gc_count) - minor, major: GC.stat(:major_gc_count) - major,
    gc_ms: GC.stat(:time) - gc_ms }
end

def with_commas(integer)
  integer.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

versions = %w[google-protobuf prometheus-client].map { |gem| "#{gem} #{Gem.loaded_specs[gem].version}" }
puts "#{RUBY_DESCRIPTION}; #{versions.join('; ')}"
puts "#{SERIES} series x #{LABELS} labels (+60 small series), #{RENDERS} timed renders each"
puts
columns = ["renderer", "output", "s/render", "objects/render", "malloc MiB/render", "live arenas after",
           "GC runs (#{RENDERS} renders)", "GC ms"]
puts "| #{columns.join(' | ')} |"
puts "|#{'---|' * columns.size}"
RENDERERS.each do |name, render|
  f = footprint(render)
  t = timed(render, RENDERS)
  cells = [name, "#{(f[:bytes] / 1e6).round(1)} MB", t[:seconds].round(3), with_commas(f[:objects]),
           f[:malloc_mib].round(1), with_commas(f[:arenas]), "#{t[:minor]} minor + #{t[:major]} major", t[:gc_ms]]
  puts "| #{cells.join(' | ')} |"
end
