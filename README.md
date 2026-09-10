# fast-prometheus

A fiber-native Prometheus client for modern Ruby. Built on the socketry/async
ecosystem: safe to share across OS threads and fibers by default, native
histograms as a first-class metric type, protobuf scrape exposition, and OTLP
export over gRPC (async-grpc) and HTTP.

Not a fork of prometheus/client_ruby — a new gem that uses it as the reference
for supported surface.

## Installation

```bash
gem install fast-prometheus
```

Or add to your `Gemfile`:

```ruby
gem "fast-prometheus"
```

`require "fast/prometheus"` loads only the core (metrics, registry,
snapshot) — zero IO dependencies. Scrape formats, HTTP middleware, and OTLP
export are opt-in surfaces that each pull their own dependencies (and require
the core themselves, so they're independently requirable):

| Require path                              | Pulls in                          |
|--------------------------------------------|------------------------------------|
| `fast/prometheus`                          | core only — no IO deps             |
| `fast/prometheus/formats/text`              | core                                |
| `fast/prometheus/formats/protobuf`          | core, google-protobuf              |
| `fast/prometheus/middleware/exporter`       | core, protocol-http, both formats  |
| `fast/prometheus/middleware/instrumentation`| core, protocol-http                |
| `fast/prometheus/otlp/mapper`               | core, vendored OTLP protos          |
| `fast/prometheus/otlp/http_exporter`        | core, async-http                    |
| `fast/prometheus/otlp/grpc_exporter`        | core, async-http, async-grpc        |
| `fast/prometheus/otlp/push`                 | core, async, console                |
| `fast/prometheus/otlp/service_interface`    | core, protocol-grpc                 |

The vendored `Opentelemetry::Proto` descriptors under `fast/prometheus/otlp/pb`
may conflict with the `opentelemetry-proto` gem if both are loaded in the same
process (duplicate protobuf descriptor registration). This only affects
processes that opt into OTLP export.

## Usage

### Registry

```ruby
require "fast/prometheus"

registry = Fast::Prometheus::Registry.new

# Or use the module-level default:
registry = Fast::Prometheus.registry
```

### Counter

A monotonically increasing metric.

```ruby
requests = registry.counter(:http_requests_total, docstring: "Total HTTP requests", labels: %i[method path])
requests.increment(labels: { method: "GET", path: "/" })
requests.increment(by: 5, labels: { method: "POST", path: "/api" })
```

### Gauge

An instantaneous value that can go up or down.

```ruby
temperature = registry.gauge(:cpu_temperature_celsius, docstring: "CPU temperature", labels: [:core])
temperature.set(72.5, labels: { core: "0" })
temperature.increment(labels: { core: "0" })
temperature.decrement(by: 5, labels: { core: "0" })
```

### Histogram

Samples observations and counts them in configurable buckets.

```ruby
duration = registry.histogram(:request_duration_seconds, docstring: "Request duration", labels: [:method])
duration.observe(0.042, labels: { method: "GET" })
```

### Summary

Accumulates observations as sum + count per label set.

```ruby
latency = registry.summary(:request_latency_seconds, docstring: "Request latency", labels: [:method])
latency.observe(0.037, labels: { method: "GET" })
```

### NativeHistogram

Sparse exponential histogram covering the full float range.

```ruby
native = registry.native_histogram(:request_duration_seconds, docstring: "Request duration", labels: [:method])
native.observe(0.042, labels: { method: "GET" })
```

### Bound Metrics (`with_labels`)

Pre-set labels for fast-path hot loops. Validation happens once at bind time.

```ruby
# Bind outside the loop
get_counter = requests.with_labels(method: "GET", path: "/")

# Hot loop — no label resolution overhead
loop do
  get_counter.increment
end
```

### Scrape Exposition

Collect an immutable snapshot and render it:

```ruby
snapshot = registry.collect
text = Fast::Prometheus::Formats::Text.render(snapshot)
protobuf = Fast::Prometheus::Formats::Protobuf.render(snapshot)
```

### `/metrics` Endpoint (Protocol::HTTP Middleware)

```ruby
require "fast/prometheus/middleware/exporter"

app = Fast::Prometheus::Middleware::Exporter.new(
  my_app,
  registry: Fast::Prometheus.registry,
  path: "/metrics"
)
```

Supports content negotiation (text vs protobuf) and gzip compression.

### OTLP Export

#### gRPC Exporter

```ruby
exporter = Fast::Prometheus::OTLP::GRPCExporter.new(
  endpoint: "http://localhost:4317",
  resource_attributes: { service: "my-app" }
)
exporter.export
exporter.close
```

#### HTTP Exporter

```ruby
exporter = Fast::Prometheus::OTLP::HTTPExporter.new(
  endpoint: "http://localhost:9090",
  resource_attributes: { service: "my-app" }
)
exporter.export
exporter.close
```

#### Push Loop

Periodically push metrics using any exporter:

```ruby
push = Fast::Prometheus::OTLP::Push.new(exporter: exporter, interval: 15)
push.run
# ... later ...
push.stop
```

## Concurrency

A `Registry` is safe to share across OS threads by default, and remains safe
across fibers within a thread. Every metric's per-series storage is guarded
by one lock, shared by every metric bound to it via `with_labels`; a mutation
(`increment`, `set`, `observe`) and a read (`get`, `values`, a snapshot) are
each a single critical section, and `collect` observes every series of a
metric at one consistent point in time. Registry operations (`register`,
`unregister`, `get`, `metrics`, `collect`) are serialized on a registry-owned
lock. This makes the library correct under Falcon `--threaded --count N`,
where one process's N OS threads (each running its own Async reactor) share
one module-level `Fast::Prometheus.registry`.

Falcon's `--forked` mode gives each process its own registry, so a single
scrape only sees the metrics of the process that handled it — aggregating
across processes is out of scope for this gem.

## Integration harness

The sus suite and `script/` E2Es run against the checkout's `lib/`, so they
can't catch packaging bugs — files missing from `spec.files`, runtime deps
declared only for tests, require-path mistakes. `integration/run` builds (or
takes) a `.gem`, installs it into an isolated `GEM_HOME`, and exercises the
full v1 surface through that installed gem only:

```bash
./integration/run                    # builds fast-prometheus.gemspec from the checkout
./integration/run path/to/some.gem   # tests a specific artifact, e.g. a downloaded release asset
E2E_REQUIRED=1 ./integration/run     # fail (rather than skip) if prometheus/promtool aren't on PATH
```

Every pre-release should pass `E2E_REQUIRED=1 ./integration/run <the-tagged-.gem>`
before the tag graduates.

## Benchmarks

`benchmark-ips` comparisons, single process, Ruby 4.0.5 on Apple M4 Pro
(arm64-darwin25):

```
Warming up --------------------------------------
                counter labels (fast)   140.435k i/100ms
   counter labels (prometheus-client)   106.893k i/100ms
                 counter bound (fast)   201.717k i/100ms
    counter bound (prometheus-client)   193.579k i/100ms
             histogram observe (fast)   173.954k i/100ms
histogram observe (prometheus-client)    56.747k i/100ms
      native histogram observe (fast)   135.968k i/100ms
Calculating -------------------------------------
                counter labels (fast)      1.446M (± 1.8%) i/s  (691.74 ns/i) -      2.949M in   2.040039s
   counter labels (prometheus-client)      1.113M (± 1.6%) i/s  (898.51 ns/i) -      2.245M in   2.016944s
                 counter bound (fast)      2.000M (± 1.6%) i/s  (499.99 ns/i) -      4.034M in   2.017128s
    counter bound (prometheus-client)      1.938M (± 1.0%) i/s  (516.10 ns/i) -      4.065M in   2.098010s
             histogram observe (fast)      1.723M (± 1.3%) i/s  (580.29 ns/i) -      3.479M in   2.018880s
histogram observe (prometheus-client)    564.954k (± 1.4%) i/s    (1.77 μs/i) -      1.135M in   2.008907s
      native histogram observe (fast)      1.363M (± 1.4%) i/s  (733.88 ns/i) -      2.855M in   2.095457s

Comparison:
                 counter bound (fast):  2000041.6 i/s
    counter bound (prometheus-client):  1937626.1 i/s - 1.03x  slower
             histogram observe (fast):  1723272.3 i/s - 1.16x  slower
                counter labels (fast):  1445626.8 i/s - 1.38x  slower
      native histogram observe (fast):  1362627.8 i/s - 1.47x  slower
   counter labels (prometheus-client):  1112947.6 i/s - 1.80x  slower
histogram observe (prometheus-client):   564954.0 i/s - 3.54x  slower
```

Key takeaways (locked, thread-safe by default):
- Bound counter (fast) is on par with prometheus-client's bound counter (1.03x)
- Classic histogram observe is **3.0x** faster (1.72M vs 565K i/s)
- Native histogram observe runs at **1.36M i/s** with no prometheus-client equivalent
