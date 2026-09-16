# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
