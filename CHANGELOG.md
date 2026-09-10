# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Registry#fetch_or_register(name, &block)` — an atomic fetch-or-register:
  returns the metric already registered under `name`, else registers and
  returns the block's metric, in one lock hold.
- `Metric#synchronize` — runs a block atomically with respect to every other
  mutation or read of that metric's store, including its `with_labels`-bound
  children.

### Fixed

- `Instrumentation` middleware: concurrent construction of the middleware
  against one registry could race two `get`/register check-then-act calls
  and raise `DuplicateMetric`; it now registers its counter and histogram
  through `Registry#fetch_or_register`.
- `Instrumentation` middleware: when the delegate raised and recording the
  failed request also raised, the recording exception replaced the
  delegate's; the delegate's exception now always propagates.

### Changed

- `Registry` and every metric type are now safe to share across OS threads by
  default: each metric's per-series store is guarded by its own lock (shared
  by `with_labels`-bound metrics), snapshot construction observes every
  series at one consistent point, and registry operations are serialized on
  a registry-owned lock. This retires the zero-lock hot-path invariant —
  cross-thread use is now in contract, not out of it.

## [0.1.0.pre.1] - 2026-07-19

### Added

- Fiber-native Prometheus client built on `async`.
- Native histograms via protobuf scrape.
- OTLP export over gRPC and HTTP.
- `Fast::Prometheus` namespace.
