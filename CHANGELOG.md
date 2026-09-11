# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
