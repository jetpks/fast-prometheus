# fast-prometheus

A fiber-native Prometheus client for modern Ruby, built on the socketry/async
ecosystem: HTTP middleware for `Protocol::HTTP` (Falcon-native) and Rack, safe
to share one `Registry` across OS threads and fibers by default, native
histograms as a first-class metric type, protobuf scrape exposition, and OTLP
export over gRPC (async-grpc) and HTTP.

Not a fork of `prometheus/client_ruby` — a new gem that uses it as the
reference for supported surface.

## Installation

```bash
gem install fast-prometheus
```

Or add to your `Gemfile`:

```ruby
gem "fast-prometheus"
```

`require "fast/prometheus"` loads only the core, with no IO dependencies. Protobuf exposition and OTLP export are built on [fast-protowire](https://github.com/jetpks/fast-protowire) rather than `google-protobuf`, so no native protobuf runtime is loaded either. The
opt-in surfaces and what each pulls in are listed in
[the require-path reference](docs/reference/require-paths.md).

## Quickstart

```ruby
require "fast/prometheus"
require "fast/prometheus/formats/text"

registry = Fast::Prometheus::Registry.new

requests = registry.counter(:http_requests_total, docstring: "Total HTTP requests", labels: %i[method path])
duration = registry.histogram(:request_duration_seconds, docstring: "Request duration", labels: [:method])

requests.increment(labels: { method: "GET", path: "/" })
requests.increment(by: 5, labels: { method: "POST", path: "/api" })
duration.observe(0.042, labels: { method: "GET" })
duration.observe(0.018, labels: { method: "GET" })

puts Fast::Prometheus::Formats::Text.render(registry.collect)
```

Run with `bundle exec ruby -I lib` from the repo root. For running this
under Falcon and scraping it with a real Prometheus, see
[the Falcon tutorial](docs/tutorials/falcon-app.md).

## Documentation

### Tutorials

- [Tutorial: instrument a Falcon app](docs/tutorials/falcon-app.md) — build a Falcon app instrumented with fast-prometheus and scrape it with Prometheus.

### How-to guides

- [How to instrument a Rack app](docs/how-to/instrument-a-rack-app.md) — add the two Rack middleware to a `config.ru`, Rails app or Puma host.
- [How to instrument a falcon.rb service](docs/how-to/instrument-a-falcon-service.md) — run the Falcon-native middleware under `falcon host` or a threaded launcher.
- [How to serve metrics on a separate port](docs/how-to/serve-metrics-on-a-separate-port.md) — run `/metrics` on its own `Async::HTTP::Server`, off the app's port.
- [How to scrape native histograms](docs/how-to/scrape-native-histograms.md) — configure Prometheus to negotiate protobuf so native histograms aren't dropped.
- [How to share one registry across boot paths](docs/how-to/share-a-registry.md) — use `fetch_or_register` so multiple boot paths can construct the same metric safely.
- [How to export over OTLP](docs/how-to/export-otlp.md) — push metrics to an OTLP collector over gRPC or HTTP.
- [How to verify a release build](docs/how-to/verify-a-release.md) — run the integration harness against a packaged gem before tagging.

### Reference

- [Reference: registry and metrics](docs/reference/metrics.md) — every public class and method on `Registry` and the five metric types.
- [Reference: exposition formats and HTTP middleware](docs/reference/exposition.md) — `Formats::Text`, `Formats::Protobuf`, `Middleware::Exporter`, `Middleware::Instrumentation`.
- [Reference: OTLP export](docs/reference/otlp.md) — `OTLP::HTTPExporter`, `OTLP::GRPCExporter`, `OTLP::Push`, `OTLP::Mapper`.
- [Reference: require paths and dependencies](docs/reference/require-paths.md) — what each require path loads and what it pulls in.

### Explanation

- [Concurrency model](docs/explanation/concurrency.md) — the locking contract and what it guarantees under threads and fibers.
- [Native histograms](docs/explanation/native-histograms.md) — what a native histogram is and why it's protobuf-only.
- [Design: why a new gem](docs/explanation/design.md) — why fast-prometheus exists instead of a `client_ruby` fork.
- [Benchmarks](docs/explanation/benchmarks.md) — the full benchmark-ips run and how to reproduce it.

## Concurrency

A `Registry` is safe to share across every OS thread of a process, and
remains safe across fibers within a thread — correct under Falcon
`--threaded --count N`, where the N OS threads share one module-level
`Fast::Prometheus.registry`. Falcon `--forked` mode gives each process its
own registry, so a single scrape only sees the metrics of the process that
handled it; aggregating across processes is out of scope. See
[the concurrency model](docs/explanation/concurrency.md) for the full guarantee.

## Performance

Single process, locked, thread-safe by default (`benchmark-ips` and allocation
comparisons against `prometheus-client` and `google-protobuf`; see
[the benchmarks page](docs/explanation/benchmarks.md) for the full runs and conditions):

- A protobuf scrape of 36,000 series renders in **183 objects**, where the
  `google-protobuf` encoder needed 3.5 million Ruby objects and 504k native arenas, and
  in a tenth of the GC time; taking the snapshot it reads is 1 ms and one Hash per metric
- The text renderer allocates **66x fewer objects** than prometheus-client's formatter
  for the same body, and renders it 2.7x faster
- Bound counter increments allocate nothing and are **1.52x** faster than
  prometheus-client's; classic histogram observe is **3.0x** faster
- Native histogram observe runs at **1.26M i/s** with no prometheus-client equivalent

## Development

```bash
bundle exec sus
bundle exec rubocop
E2E_REQUIRED=1 ./integration/run
```

See [how to verify a release build](docs/how-to/verify-a-release.md) for the pre-release rule.
