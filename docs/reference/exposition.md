# Reference: exposition formats and HTTP middleware

## `Formats::Text`

Renders a `Snapshot` as Prometheus text exposition format 0.0.4. Consumes only `Snapshot` value objects, never live metrics.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `.render(snapshot)` | `String` | Content type `Formats::Text::CONTENT_TYPE` (`"text/plain; version=0.0.4; charset=utf-8"`). Metrics of type `:native_histogram` are omitted entirely — no `HELP`/`TYPE` lines, no series. |

## `Formats::Protobuf`

Renders a `Snapshot` as delimited Prometheus protobuf exposition (`io.prometheus.client.MetricFamily`).

Methods

| Signature | Returns | Notes |
|---|---|---|
| `.render(snapshot)` | `String` | Content type `Formats::Protobuf::CONTENT_TYPE` (`"application/vnd.google.protobuf; proto=io.prometheus.client.MetricFamily; encoding=delimited"`). One length-prefixed (varint) `MetricFamily` frame per metric, concatenated. `:native_histogram` series map to a protobuf `Histogram` with `schema`/`zero_threshold`/`zero_count`/`positive_span`/`positive_delta`/`negative_span`/`negative_delta` set. |

## `Middleware::Exporter`

`Protocol::HTTP::Middleware` that serves metrics at a configurable path, with content negotiation and gzip.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `delegate` (positional) | required | The wrapped `Protocol::HTTP` app. |
| `registry:` | `Fast::Prometheus.registry` | Registry to collect from. |
| `path:` | `"/metrics"` | Request path this middleware serves. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `call(request)` | `Protocol::HTTP::Response` | Serves metrics for a `GET` at `path`; otherwise delegates to the wrapped app. |
| `serve_metrics(request)` | `Protocol::HTTP::Response` | `200` with the negotiated body. |
| `protobuf?(request)` | `true`/`false` | `true` when the `Accept` header's value includes `"application/vnd.google.protobuf"`; otherwise text. |
| `gzip?(request)` | `true`/`false` | `true` when the `Accept-Encoding` header's value includes `"gzip"`; response then carries `content-encoding: gzip`. |

## `Middleware::Instrumentation`

`Protocol::HTTP::Middleware` that records RED metrics for every request.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `delegate` (positional) | required | The wrapped `Protocol::HTTP` app. |
| `registry:` | `Fast::Prometheus.registry` | Registry the metrics are registered on. |
| `native:` | `false` | When `true`, the duration metric is a `NativeHistogram` instead of a `Histogram`. |
| `prefix:` | `"http_server"` | Prefix for both metric names. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `call(request)` | `Protocol::HTTP::Response` | Times and delegates the request, then records it. On the delegate raising, records the request with `status: "500"` and re-raises the original exception. |

Metric names and labels (both labelled `method`, `status`):

| Name | Type | Notes |
|---|---|---|
| `<prefix>_requests_total` | `Counter` | Incremented once per request. |
| `<prefix>_request_duration_seconds` | `Histogram`, or `NativeHistogram` when `native: true` | Observed once per request, in seconds. |

Both metrics are obtained via `registry.fetch_or_register`, so a metric already registered under either name — by application code, at boot — is reused instead of re-registered, as long as it declares `labels: %i[method status]`.
