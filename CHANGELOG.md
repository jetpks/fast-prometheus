# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Protobuf exposition and OTLP export no longer use `google-protobuf`. The
  Prometheus client model and the OTLP messages are declared with
  [fast-protowire](https://github.com/jetpks/fast-protowire), a wire-format
  library with no native extension: no per-message arenas, no object cache,
  no descriptor pool. Output is byte-identical (tests decode it with
  google-protobuf as a development dependency). `Formats::Protobuf.render`
  encodes each series on its own and appends it to the family's bytes, so a
  36k-series scrape peaks at roughly the body size instead of ~320 MiB.
- `OTLP::Mapper#request` returns a `Fast::Prometheus::OTLP::Proto::
  ExportMetricsServiceRequest`; the gRPC interface's response class is
  `Fast::Prometheus::OTLP::Proto::ExportMetricsServiceResponse`.
- New `script/scrape_rss.rb`: an RSS-per-scrape harness for the exposition
  path (forked server scraped over keep-alive, or in-process loops).
- `Formats::Text.render` and `Formats::Protobuf.render` allocate per sample
  and per series, not per label: text appends every piece straight into the
  output (one String per sample line, the value), and protobuf writes each
  series' bytes with `Fast::Protowire::Wire` into one reused scratch buffer,
  with no message objects. Over 5,200 series x 12 labels a text render went
  from 100,840 to 10,631 objects and a protobuf render from 342,705 to 6,165
  (0.114 s to 0.030 s); in the 36k-series server harness, protobuf+gzip
  scrapes went from 0.92 s to 0.25 s and text from 0.20 s to 0.08 s.
- `MetricSnapshot#series` is the metric's store copied under its lock: a
  frozen `Hash` from each series' label values (an `Array` in `label_names`
  order) to its value, with `MetricSnapshot#labels(values)` for the
  `{name => value}` view. The `Series` object and its per-series label Hash
  are gone, and with them the snapshot's per-series cost: `Registry#collect`
  over 36,000 series x 12 labels went from 34 ms, 72,056 objects and 19 MiB
  to 1 ms, 342 objects and the 2 MiB copy. `Metric#snapshot_values` is keyed
  the same way; `Metric#values` keeps its label-Hash keys. `HistogramValue`,
  `SummaryValue` and `NativeHistogramValue` are frozen `Struct`s rather than
  `Data`, since `Data.new` allocates two objects besides the instance;
  `Histogram#cumulative_buckets` and the native histogram bucket readers
  return frozen pairs.
- A bound or unlabeled `increment`/`observe`/`set` allocates nothing (the
  `labels: {}` default is one shared frozen Hash and the store lock is taken
  with `yield`, not a captured block); a labeled call allocates only its
  resolved key. `test/fast/prometheus/allocations.rb` freezes these budgets.
- `fast-protowire` is resolved from rubygems.org (`~> 0.1`); the
  sibling-path override is gone from `gems.rb`. Development and the
  published benchmarks are on Ruby 4.0.7 (`mise.toml`, CI's dev row).

### Added

- `benchmark/exposition.rb`, a scrape benchmark suite: end-to-end scrapes
  through `Middleware::Exporter` over `Async::HTTP` in every content variant,
  each stage of a scrape on its own (collect, render, gzip) with objects and
  malloc bytes, the renderers against `prometheus-client`'s text formatter
  from 1k to 100k series, and the protobuf renderer against the two
  google-protobuf encoders this gem used to ship with live native arenas and
  GC time. `benchmark/observe.rb` reports every metric operation against
  `prometheus-client` as one table: i/s, speedup and objects per call.

## [0.2.0] - 2026-09-15

### Added

- `Registry#exist?(name)` — true iff a metric is registered under `name`.
- `Metric#init_label_set(labels)` is now public: it resolves `labels` like any
  mutator and creates that series at the type's zero value under the store
  lock, only if it's absent — it never resets a live series.
- Every metric now seeds a zero-valued series at construction when it's fully
  bound (no declared labels, or `preset_labels:` covers every declared
  label); a fully-bound `with_labels` child seeds its own series the same
  way. A seeded series shows up in `values`, `Registry#collect`, and text/
  protobuf exposition at zero — for example a freshly registered counter now
  renders `requests_total 0.0` instead of being absent from scrapes until
  first incremented. Partially-bound metrics and zero-valued
  `increment`/`decrement` still seed nothing; `get` still never creates a
  series.
- `Gauge#set_to_current_time(labels: {})` — `set(Time.now.to_f, labels:
  labels)`.
- `Metric#snapshot_values` — every series' value in its frozen snapshot shape
  (`HistogramValue`, `SummaryValue`, `NativeHistogramValue`, or the
  already-frozen `Float` for `Counter`/`Gauge`), keyed by label hash, built
  under the store lock.

### Changed

- **Breaking:** `Metric` names may now be given as a `String` or a `Symbol`
  and are normalized to a `Symbol` on construction; `Metric#name` always
  returns a `Symbol` where it previously echoed back whatever was passed in.
  `Registry#unregister`, `#get`, `#exist?`, and `#fetch_or_register` accept
  either form and symbolize it before lookup; `DuplicateMetric` now fires
  across forms (registering `"requests_total"` after `:requests_total` is
  already registered raises).
- **Breaking:** `Metric#label_names` is renamed to `Metric#labels`; the old
  name no longer exists (no alias). `MetricSnapshot#label_names` is
  unaffected.
- **Breaking:** `Histogram#get`/`#values` and `Summary#get`/`#values` now
  return prometheus-client-shaped hashes instead of the internal
  `HistogramSlot`/`Summary::Value` storage objects. `Histogram#get` returns a
  fresh `Hash` keyed by each bucket boundary's `to_s` (ascending), then
  `"+Inf"`, then `"sum"`, with cumulative `Integer` bucket counts and a
  `Float` sum; `Summary#get` returns `{ "count" => Integer, "sum" => Float }`.
  `Histogram#cumulative_buckets`, `#sum`, and `#count` now return zero-valued
  results for an unobserved series instead of `nil`. `NativeHistogram#get`/
  `#values` now return the frozen `NativeHistogramValue` snapshot type
  (previously the internal `NativeHistogram::Slot`), including a zero-valued
  value for an unobserved series. All of these are fresh copies per call;
  mutating a returned `Hash` no longer affects the metric.
- `Fast::Prometheus.registry=` now assigns under the same lock the reader
  uses, closing a race between a writer and a concurrent reader/memoizing
  first read.

## [0.1.0] - 2026-09-11

### Added

- `Registry#fetch_or_register(name, &block)` — an atomic fetch-or-register:
  returns the metric already registered under `name`, else registers and
  returns the block's metric, in one lock hold.
- `Metric#synchronize` — runs a block atomically with respect to every other
  mutation or read of that metric's store, including its `with_labels`-bound
  children.
- `Fast::Prometheus::Rack::Exporter` and `Fast::Prometheus::Rack::Instrumentation` —
  plain Rack middleware for `config.ru`, Rails, Puma and any other Rack host,
  built on the same content-negotiation and RED-recording core as the
  Falcon-native `Middleware::Exporter`/`Middleware::Instrumentation`.

### Fixed

- `Instrumentation` middleware: concurrent construction of the middleware
  against one registry could race two `get`/register check-then-act calls
  and raise `DuplicateMetric`; it now registers its counter and histogram
  through `Registry#fetch_or_register`.
- `Instrumentation` middleware: when the delegate raised and recording the
  failed request also raised, the recording exception replaced the
  delegate's; the delegate's exception now always propagates.

### Changed

- Minimum Ruby lowered from 3.4 to 3.3 (`required_ruby_version >= 3.3`); the
  test suite, RuboCop, the integration harness and the thread-safety stress
  harness all pass on 3.3.12 and 4.0.5, and CI now runs the suite on both.
- `Registry` and every metric type are now safe to share across OS threads by
  default: each metric's per-series store is guarded by its own lock (shared
  by `with_labels`-bound metrics), snapshot construction observes every
  series at one consistent point, and registry operations are serialized on
  a registry-owned lock. This retires the zero-lock hot-path invariant —
  cross-thread use is now in contract, not out of it.
- Documentation reorganized: `README.md` is now a front door, and the
  tutorials, how-to guides, reference, and explanation live under `docs/`
  per the Diátaxis framework.
- `Formats::Text` and `Formats::Protobuf` expose only `.render`; the
  rendering helpers they used to leak as public singleton methods are private.

## [0.1.0.pre.1] - 2026-07-19

### Added

- Fiber-native Prometheus client built on `async`.
- Native histograms via protobuf scrape.
- OTLP export over gRPC and HTTP.
- `Fast::Prometheus` namespace.
