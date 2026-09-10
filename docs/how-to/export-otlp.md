# How to export over OTLP

Push a registry's metrics to an OTLP metrics receiver (e.g. an OpenTelemetry Collector, or
Prometheus started with `--web.enable-otlp-receiver`) instead of waiting for it to scrape
you. You need an `Async` reactor and a reachable OTLP endpoint.

## Steps

1. Require the exporter for your transport and build one. Over gRPC:

   ```ruby
   require "fast/prometheus/otlp/grpc_exporter"

   exporter = Fast::Prometheus::OTLP::GRPCExporter.new(
     endpoint: "http://localhost:4317",
     registry: Fast::Prometheus.registry,
     resource_attributes: { service: "my-app" },
     headers: {}
   )
   ```

   Over HTTP:

   ```ruby
   require "fast/prometheus/otlp/http_exporter"

   exporter = Fast::Prometheus::OTLP::HTTPExporter.new(
     endpoint: "http://localhost:9090",
     registry: Fast::Prometheus.registry,
     resource_attributes: { service: "my-app" },
     headers: {}
   )
   ```

   Both default `registry:` to `Fast::Prometheus.registry`, `resource_attributes:` and
   `headers:` to `{}`.

2. Export once, on demand:

   ```ruby
   exporter.export
   ```

   `export` collects a fresh snapshot from `registry` (or takes one you pass in) and sends
   it; it raises on a non-2xx response.

3. Or push on an interval, from inside an `Async` block:

   ```ruby
   require "fast/prometheus/otlp/push"

   Async do |task|
     push = Fast::Prometheus::OTLP::Push.new(exporter: exporter, interval: 15)
     push.run(parent: task)
     # ... later, e.g. on shutdown ...
     push.stop
   end
   ```

   `interval` defaults to `15` seconds; `run`'s `parent:` defaults to `Async::Task.current`.
   A failed export inside the loop is logged and the loop continues rather than raising.

4. Close the exporter's underlying HTTP client when you're done with it:

   ```ruby
   exporter.close
   ```

## Result

Your metrics land in the OTLP receiver as OpenTelemetry `Sum`/`Gauge`/`Histogram`/`Summary`/
`ExponentialHistogram` data points, one export per call (or one per `interval`).

If your process also loads the `opentelemetry-proto` gem, expect a duplicate protobuf
descriptor registration warning at boot: `fast-prometheus` vendors its own copy of the
`Opentelemetry::Proto` descriptors under `fast/prometheus/otlp/pb`, and having both loaded in
the same process registers the same descriptors twice. This only affects processes that
require an OTLP surface.

See [Reference: OTLP export](../reference/otlp.md) for the full constructor keyword list and
`OTLP::Mapper`, and [Reference: require paths and dependencies](../reference/require-paths.md)
for what each `otlp/*` require path pulls in.
