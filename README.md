# fast-prometheus

A fiber-native Prometheus client for modern Ruby. Built on the socketry/async
ecosystem: zero-lock hot path under cooperative scheduling, native histograms
as a first-class metric type, protobuf scrape exposition, and OTLP export over
gRPC (async-grpc) and HTTP.

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

## Fiber-Atomicity Invariant

Metric updates perform no blocking operations between reading and writing a
storage slot. Under cooperative scheduling (Async/IO), plain Hash
read-modify-write is fiber-atomic with no mutex. This is the foundation of
the zero-lock hot path: every `increment`, `observe`, and `set` is a single
non-blocking Hash mutation.

Cross-thread use is out of contract — if you need thread safety, wrap the
registry or metrics with Ruby's `Monitor` or `Mutex` externally.

## Benchmarks

`benchmark-ips` comparisons, single process, Ruby 4.0.5 on Apple M4 Pro
(arm64-darwin25):

```
Warming up --------------------------------------
                counter labels (fast)    98.092k i/100ms
   counter labels (prometheus-client)    87.610k i/100ms
                 counter bound (fast)   199.353k i/100ms
    counter bound (prometheus-client)   155.526k i/100ms
             histogram observe (fast)   122.910k i/100ms
histogram observe (prometheus-client)    44.705k i/100ms
      native histogram observe (fast)   104.543k i/100ms
Calculating -------------------------------------
                counter labels (fast)    975.979k (± 0.4%) i/s    (1.02 μs/i) -      1.962M in   2.010126s
   counter labels (prometheus-client)    878.694k (± 0.5%) i/s    (1.14 μs/i) -      1.840M in   2.093800s
                 counter bound (fast)      2.001M (± 0.5%) i/s  (499.72 ns/i) -      4.186M in   2.092052s
    counter bound (prometheus-client)      1.539M (± 2.2%) i/s  (649.93 ns/i) -      3.111M in   2.021608s
             histogram observe (fast)      1.218M (± 0.9%) i/s  (820.81 ns/i) -      2.458M in   2.017704s
histogram observe (prometheus-client)    448.711k (± 0.5%) i/s    (2.23 μs/i) -    938.805k in   2.092228s
      native histogram observe (fast)      1.052M (± 0.3%) i/s  (950.52 ns/i) -      2.195M in   2.086774s

Comparison:
                 counter bound (fast):  2001103.7 i/s
    counter bound (prometheus-client):  1538636.6 i/s - 1.30x  slower
             histogram observe (fast):  1218315.5 i/s - 1.64x  slower
      native histogram observe (fast):  1052055.9 i/s - 1.90x  slower
                counter labels (fast):   975978.6 i/s - 2.05x  slower
   counter labels (prometheus-client):   878694.2 i/s - 2.28x  slower
histogram observe (prometheus-client):   448710.7 i/s - 4.46x  slower
```

Key takeaways:
- Bound counter (fast) is **1.3x** faster than prometheus-client's bound counter
- Classic histogram observe is **2.7x** faster (1.2M vs 449K i/s)
- Native histogram observe runs at **1.05M i/s** with no prometheus-client equivalent
