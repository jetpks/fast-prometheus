# Reference: OTLP export

## `OTLP::HTTPExporter`

Exports a snapshot over HTTP to an OTLP receiver (e.g. `prometheus --web.enable-otlp-receiver`).

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `endpoint:` | required | Base URL; requests POST to `"#{endpoint}/v1/metrics"`. |
| `registry:` | `Fast::Prometheus.registry` | Registry `export` collects from when no snapshot is given. |
| `resource_attributes:` | `{}` | Attached to the OTLP `Resource` on every export. |
| `headers:` | `{}` | Extra HTTP headers, merged after a fixed `content-type: application/x-protobuf`. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `export(snapshot = registry.collect)` | `nil` | POSTs the mapped request. Raises `Fast::Prometheus::Error` if the response status is not in `200..299`. |
| `close` | — | Closes the underlying `Async::HTTP::Internet`. |

## `OTLP::GRPCExporter`

Exports a snapshot over gRPC using `async-grpc`.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `endpoint:` | required | Parsed as an `Async::HTTP::Endpoint` over HTTP/2. |
| `registry:` | `Fast::Prometheus.registry` | Registry `export` collects from when no snapshot is given. |
| `resource_attributes:` | `{}` | Attached to the OTLP `Resource` on every export. |
| `headers:` | `{}` | gRPC call headers. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `export(snapshot = registry.collect)` | the stub's `Export` RPC response | Calls `MetricsService/Export` over gRPC. |
| `close` | — | Closes the underlying `Async::HTTP::Client`. |

## `OTLP::Push`

Periodically calls `#export` on any exporter, inside an `Async` reactor.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `exporter:` | required | Any object responding to `#export`. |
| `interval:` | `15` | Seconds slept between exports. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `run(parent: Async::Task.current)` | `Async::Task` | Starts an async task looping `sleep(interval)` then `exporter.export`; a `StandardError` from one export is logged (`Console.warn`) and the loop continues. Stores and returns the task. |
| `stop` | `nil` | Stops the running task, if any. |

## `OTLP::Mapper`

Maps a `Snapshot` to an `Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest`. Used internally by both exporters.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `resource_attributes:` | `{}` | Converted to OTLP `KeyValue` attributes on the request's `Resource`. |
| `start_time:` | `Time.now` | Used as `start_time_unix_nano` on every data point (cumulative aggregation start). |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `request(snapshot)` | `Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest` | `:counter`/`:gauge` map to OTLP `Sum`/`Gauge`; `:histogram` maps to OTLP `Histogram` (cumulative); `:summary` maps to OTLP `Summary`; `:native_histogram` maps to OTLP `ExponentialHistogram`, with `scale: schema` and OTLP bucket offsets equal to `prom_index - 1`. |

The vendored `Opentelemetry::Proto` descriptors this module loads (under `fast/prometheus/otlp/pb`) may conflict with the `opentelemetry-proto` gem if both register the same protobuf descriptors in one process; see [Reference: require paths and dependencies](require-paths.md).
