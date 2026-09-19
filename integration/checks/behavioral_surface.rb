# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/formats/text"
require "fast/prometheus/formats/protobuf"
require "open3"

def check(id)
  yield
  puts "CHECK #{id}: PASS"
rescue StandardError => e
  puts "CHECK #{id}: FAIL #{e.class}: #{e.message}"
end

def assert(condition, message)
  raise message unless condition
end

def assert_eq(actual, expected, message)
  raise "#{message} (expected #{expected.inspect}, got #{actual.inspect})" unless (actual - expected).abs < 1e-9
end

def decode_delimited_families(body)
  offset = 0
  families = []
  while offset < body.bytesize
    len = 0
    shift = 0
    loop do
      byte = body.getbyte(offset)
      offset += 1
      len |= (byte & 0x7f) << shift
      break if (byte & 0x80).zero?

      shift += 7
    end
    families << Fast::Prometheus::Formats::Protobuf::Proto::MetricFamily.decode(body[offset, len])
    offset += len
  end
  families
end

check("metric-surface") do
  registry = Fast::Prometheus::Registry.new

  # Unlabeled: metrics with no declared labels.
  counter = registry.counter(:msc_counter, docstring: "d")
  counter.increment
  assert_eq(counter.get, 1.0, "unlabeled counter mismatch")

  gauge = registry.gauge(:msc_gauge, docstring: "d")
  gauge.set(5)
  assert_eq(gauge.get, 5.0, "unlabeled gauge mismatch")

  histogram = registry.histogram(:msc_histogram, docstring: "d")
  histogram.observe(0.1)
  assert(histogram.get, "unlabeled histogram slot missing")

  summary = registry.summary(:msc_summary, docstring: "d")
  summary.observe(1.0)
  assert(summary.get, "unlabeled summary slot missing")

  nh = registry.native_histogram(:msc_nh, docstring: "d")
  nh.observe(1.5)
  assert(nh.get, "unlabeled native_histogram slot missing")

  # Labeled: declared label, exercised with falsy per-call label values.
  labeled_counter = registry.counter(:msc_counter_labeled, docstring: "d", labels: %i[flag])
  labeled_counter.increment(by: 2, labels: { flag: false })
  assert_eq(labeled_counter.get(labels: { flag: false }), 2.0, "falsy(false) label counter did not round-trip")

  labeled_gauge = registry.gauge(:msc_gauge_labeled, docstring: "d", labels: %i[flag])
  labeled_gauge.set(9, labels: { flag: 0 })
  assert_eq(labeled_gauge.get(labels: { flag: 0 }), 9.0, "falsy(0) label gauge did not round-trip")

  labeled_histogram = registry.histogram(:msc_histogram_labeled, docstring: "d", labels: %i[flag])
  labeled_histogram.observe(0.2, labels: { flag: "" })
  assert(labeled_histogram.get(labels: { flag: "" }), "falsy('') label histogram did not round-trip")

  labeled_summary = registry.summary(:msc_summary_labeled, docstring: "d", labels: %i[flag])
  labeled_summary.observe(2.0, labels: { flag: false })
  assert(labeled_summary.get(labels: { flag: false }), "falsy(false) label summary did not round-trip")

  labeled_nh = registry.native_histogram(:msc_nh_labeled, docstring: "d", labels: %i[flag])
  labeled_nh.observe(2.5, labels: { flag: false })
  assert(labeled_nh.get(labels: { flag: false }), "falsy(false) label native_histogram did not round-trip")

  # with_labels on every metric type: kwargs (including construction options) must forward.
  bound_counter = labeled_counter.with_labels(flag: "x")
  bound_counter.increment(by: 3)
  assert_eq(labeled_counter.get(labels: { flag: "x" }), 3.0, "with_labels counter did not forward")

  bound_gauge = labeled_gauge.with_labels(flag: "x")
  bound_gauge.set(7)
  assert_eq(labeled_gauge.get(labels: { flag: "x" }), 7.0, "with_labels gauge did not forward")

  bound_histogram = labeled_histogram.with_labels(flag: "x")
  bound_histogram.observe(0.05)
  assert(labeled_histogram.get(labels: { flag: "x" }), "with_labels histogram did not forward")
  assert(bound_histogram.buckets == labeled_histogram.buckets, "with_labels histogram lost buckets kwarg")

  bound_summary = labeled_summary.with_labels(flag: "x")
  bound_summary.observe(4.0)
  assert(labeled_summary.get(labels: { flag: "x" }), "with_labels summary did not forward")

  bound_nh = labeled_nh.with_labels(flag: "x")
  bound_nh.observe(3.0)
  assert(labeled_nh.get(labels: { flag: "x" }), "with_labels native_histogram did not forward")
  assert(bound_nh.schema == labeled_nh.schema, "with_labels native_histogram lost schema kwarg")
  assert(bound_nh.zero_threshold == labeled_nh.zero_threshold, "with_labels native_histogram lost zero_threshold kwarg")
end

check("registry") do
  registry = Fast::Prometheus::Registry.new
  registry.counter(:reg_dup, docstring: "d")

  begin
    registry.counter(:reg_dup, docstring: "d")
    raise "expected DuplicateMetric"
  rescue Fast::Prometheus::DuplicateMetric
    nil
  end

  begin
    registry.counter(:"1bad-name", docstring: "d")
    raise "expected InvalidMetricName"
  rescue Fast::Prometheus::InvalidMetricName
    nil
  end

  begin
    registry.counter(:reg_bad_label, docstring: "d", labels: [:__reserved])
    raise "expected InvalidLabelName"
  rescue Fast::Prometheus::InvalidLabelName
    nil
  end

  c = registry.counter(:reg_snapshot, docstring: "d")
  c.increment(by: 1)
  snapshot = registry.collect
  before = snapshot.metrics.find { |m| m.name == :reg_snapshot }.series.values.first
  c.increment(by: 100)
  still = snapshot.metrics.find { |m| m.name == :reg_snapshot }.series.values.first
  assert_eq(before, 1.0, "snapshot is not point-in-time (pre-mutation value already wrong)")
  assert_eq(still, 1.0, "snapshot is not point-in-time: mutated after later increment")
end

check("text-promtool") do
  registry = Fast::Prometheus::Registry.new
  registry.counter(:tp_requests_total, docstring: "Total requests").increment(by: 5)
  registry.gauge(:tp_temperature, docstring: "Temperature").set(22.5)
  registry.histogram(:tp_latency_seconds, docstring: "Latency").observe(0.2)
  registry.summary(:tp_dist_seconds, docstring: "Distribution").observe(0.3)

  text = Fast::Prometheus::Formats::Text.render(registry.collect)

  promtool = ENV.fetch("PROMTOOL_BIN")
  stdout, stderr, status = Open3.capture3(promtool, "check", "metrics", stdin_data: text)
  assert(status.success?, "promtool check metrics failed:\n#{stdout}#{stderr}")
end

check("protobuf-roundtrip") do
  registry = Fast::Prometheus::Registry.new
  registry.counter(:pr_requests_total, docstring: "Total requests").increment(by: 5)
  nh = registry.native_histogram(:pr_duration_seconds, docstring: "Duration")
  nh.observe(0.05)
  nh.observe(1.5)

  body = Fast::Prometheus::Formats::Protobuf.render(registry.collect)
  families = decode_delimited_families(body)

  assert(families.length == 2, "expected 2 decoded families, got #{families.length}")

  nh_family = families.find { |f| f.name == "pr_duration_seconds" }
  assert(nh_family, "native histogram family missing from protobuf round-trip")
  assert(nh_family.type == :HISTOGRAM, "native histogram family has wrong type: #{nh_family.type}")

  hist = nh_family.metric.first.histogram
  assert(
    !hist.positive_span.empty? || !hist.positive_delta.empty?,
    "native histogram round-trip lost positive buckets"
  )
end
