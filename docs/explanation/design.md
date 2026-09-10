# Design: why a new gem

fast-prometheus is not a fork of `prometheus/client_ruby` — it's a new gem that uses
`client_ruby` as the reference for which surface (metric types, `with_labels`, `collect`,
the exposition formats) is worth supporting, while making different choices about runtime
and concurrency underneath it.

## Fiber-native on socketry/async

`client_ruby` predates Ruby's fiber scheduler and async ecosystem; it's built around
threads and blocking IO. fast-prometheus targets the socketry/async stack directly: its OTLP
exporters use `async-http` and `async-grpc`, and its `Push` loop runs as an `Async::Task`.
Locking throughout the library uses `Thread::Mutex`/`Monitor`, both of which integrate with
`Fiber.scheduler` — a fiber contending a lock yields to its reactor instead of blocking the
thread (see [Concurrency model](concurrency.md)) — so the library composes with a
fiber-per-request server like Falcon without adding its own scheduling layer.

## Layered require paths

`require "fast/prometheus"` loads only the core: metrics, the registry, and snapshots, with
zero IO dependencies. Every other surface — the text and protobuf exposition formats, the
HTTP middleware, each OTLP exporter — is its own require path that pulls in only the
dependencies it needs (and requires the core itself, so each is independently requirable).
A process that only records metrics in memory, or only renders text exposition, never loads
`async-grpc` or the vendored OTLP protobuf descriptors. See
[Reference: require paths and dependencies](../reference/require-paths.md) for the full
table.

## Native histograms first-class

Native (sparse exponential) histograms are a metric type in their own right
(`NativeHistogram`), not an afterthought bolted onto `Histogram`. See
[Native histograms](native-histograms.md) for the schema/zero-threshold model and why they
only travel over protobuf exposition.

## Protobuf exposition and OTLP as a peer of scrape

Because native histograms need protobuf, protobuf exposition (`Formats::Protobuf`) is a
first-class rendering target next to text, not a later addition. OTLP export
(`OTLP::HTTPExporter`, `OTLP::GRPCExporter`, `OTLP::Push`) is built as a peer path to being
scraped, not a wrapper around it: an application can push to an OTLP receiver on its own
schedule, be scraped, or both, from the same registry.

## Thread-safe by default

The concurrency model is a deliberate, named decision, not the default that fell out of
avoiding effort elsewhere: "it's just not that useful to be zero-lock at this point in time
in the ruby ecosystem." A `Registry` shared across every OS thread of a Falcon
`--threaded --count N` process, and across every fiber within each thread, must be correct
without the caller adding their own locking — see [Concurrency model](concurrency.md) for
the guarantees this buys and [Benchmarks](benchmarks.md) for what the locking costs.
