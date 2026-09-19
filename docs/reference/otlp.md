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

Maps a `Snapshot` to a `Fast::Prometheus::OTLP::Proto::ExportMetricsServiceRequest` (declared with fast-protowire; `encode`/`to_proto` give the bytes). Used internally by both exporters.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `resource_attributes:` | `{}` | Converted to OTLP `KeyValue` attributes on the request's `Resource`. Keys may be Symbols or Strings and are stringified. Values keep their type: `String` → `string_value`, `Integer` → `int_value`, `Float` → `double_value`, `true`/`false` → `bool_value`, anything else its `to_s` into `string_value`. (Label attributes on a data point are always `string_value`.) |
| `start_time:` | `Time.now` | Used as `start_time_unix_nano` on every data point (cumulative aggregation start). A `Time`: it and `snapshot.taken_at` are carried as exact nanoseconds (`tv_sec`/`tv_nsec`), never through a `Float`. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `request(snapshot)` | `Fast::Prometheus::OTLP::Proto::ExportMetricsServiceRequest` | `:counter`/`:gauge` map to OTLP `Sum`/`Gauge`; `:histogram` maps to OTLP `Histogram` (cumulative); `:summary` maps to OTLP `Summary`; `:native_histogram` maps to OTLP `ExponentialHistogram`, whose `scale` is the series' `schema` — one step coarser for each halving the mapper needs to fit a wide series into 1024 dense buckets per side (see below) — and whose bucket offsets are `prom_index - 1` at that scale. |

An `ExponentialHistogram` data point carries only its series' **finite** observations: OTLP
has no bucket for an infinity and no count for a NaN, so `±Inf` (which `NativeHistogram`
clamps into a bucket) and NaN are left out of `count` and out of both bucket arrays, and
`sum` is omitted — the field is `optional` — once the series' accumulated sum is no longer
finite. A series whose buckets would need more than 1024 dense slots on either side is
merged to a coarser `scale` (halving resolution, as `NativeHistogram` downscales) until it
fits, so no export sizes an array by the distance between two observations.

No protobuf descriptors are registered by this module; see [Reference: require paths and dependencies](require-paths.md).
