# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/formats/text"
require "fast/prometheus/formats/protobuf"

# Allocation budgets for the hot paths: what an observation costs, and what
# a scrape costs per series. Counts are Ruby objects (GC.stat), so they are
# exact and the same on every platform.
describe "allocations" do
  # Objects allocated per run of the block, averaged over +times+ runs so a
  # one-off allocation outside the block (GC.stat's own, under coverage)
  # does not count.
  def allocations(times = 1, &block)
    before = GC.stat(:total_allocated_objects)
    times.times(&block)
    (GC.stat(:total_allocated_objects) - before) / times.to_f
  end

  let(:registry) { Fast::Prometheus::Registry.new }

  def wide_registry(series, labels: 4)
    names = Array.new(labels) { |i| :"label_#{i}" }
    counter = registry.counter(:events_total, docstring: "events", labels: names)
    series.times { |n| counter.increment(labels: names.to_h { |name| [name, "#{name}-#{n}"] }) }
    histogram = registry.histogram(:seconds, docstring: "seconds", labels: [:path])
    histogram.observe(0.3, labels: { path: "/a" })
    registry
  end

  it "increments a bound counter without allocating" do
    bound = registry.counter(:hits, docstring: "hits", labels: [:path]).with_labels(path: "/")
    bound.increment
    expect(allocations(100) { bound.increment }).to be(:<, 1)
  end

  it "increments an unlabeled counter without allocating" do
    counter = registry.counter(:hits, docstring: "hits")
    counter.increment
    expect(allocations(100) { counter.increment }).to be(:<, 1)
  end

  it "resolves a labeled increment with one object (its key)" do
    counter = registry.counter(:hits, docstring: "hits", labels: %i[method status])
    labels = { method: "GET", status: "200" }
    counter.increment(labels: labels)
    expect(allocations(100) { counter.increment(labels: labels) }).to be(:<, 2)
  end

  # An ASCII-only value is kept as is whatever it is tagged with, so a Rack
  # env's BINARY String costs no more than a UTF-8 literal.
  it "resolves a BINARY-tagged ASCII label value with one object (its key)" do
    counter = registry.counter(:hits, docstring: "hits", labels: [:method])
    labels = { method: "GET".b }
    counter.increment(labels: labels)
    expect(allocations(100) { counter.increment(labels: labels) }).to be(:<, 2)
  end

  it "resolves an Integer label value with two objects (its to_s and its key)" do
    counter = registry.counter(:hits, docstring: "hits", labels: [:status])
    labels = { status: 200 }
    counter.increment(labels: labels)
    expect(allocations(100) { counter.increment(labels: labels) }).to be(:<, 3)
  end

  it "resolves a Symbol label value with two objects (its to_s and its key)" do
    counter = registry.counter(:hits, docstring: "hits", labels: [:method])
    labels = { method: :get }
    counter.increment(labels: labels)
    expect(allocations(100) { counter.increment(labels: labels) }).to be(:<, 3)
  end

  # Normalizing a label value to UTF-8 allocates nothing when it already is
  # valid UTF-8, even for a String the metric has never seen: building the
  # value costs what it costs, and the increment still adds only its key. The
  # budget is measured against that baseline so it holds whatever a fresh
  # non-ASCII String costs on the day.
  it "resolves a new UTF-8 label value per call with one object beyond it" do
    counter = registry.counter(:hits, docstring: "hits", labels: [:path])
    labels = { path: "/café" }
    counter.increment(labels: labels)
    value = allocations(100) { labels[:path] = +"/café" }
    expect(allocations(100) do
      labels[:path] = +"/café"
      counter.increment(labels: labels)
    end).to be(:<, value + 2)
  end

  it "observes a labeled histogram with one object (its key)" do
    histogram = registry.histogram(:seconds, docstring: "seconds", labels: [:method])
    labels = { method: "GET" }
    histogram.observe(0.1, labels: labels)
    expect(allocations(100) { histogram.observe(0.1, labels: labels) }).to be(:<, 2)
  end

  it "collects a snapshot in a handful of objects, whatever the series count" do
    series = 500
    wide_registry(series)
    registry.collect
    expect(allocations { registry.collect }).to be(:<, 100)
  end

  it "renders text in about one object per sample line" do
    series = 500
    snapshot = wide_registry(series).collect
    output = Fast::Prometheus::Formats::Text.render(snapshot)
    expect(allocations { Fast::Prometheus::Formats::Text.render(snapshot) }).to be(:<, output.count("\n") * 2)
  end

  it "renders protobuf in about one object per series" do
    series = 500
    snapshot = wide_registry(series).collect
    Fast::Prometheus::Formats::Protobuf.render(snapshot)
    expect(allocations { Fast::Prometheus::Formats::Protobuf.render(snapshot) }).to be(:<, series * 2)
  end
end
