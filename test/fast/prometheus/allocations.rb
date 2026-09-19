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
