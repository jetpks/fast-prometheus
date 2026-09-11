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
| `call(request)` | `Protocol::HTTP::Response` | Serves metrics for a `GET` at `path`; otherwise delegates to the wrapped app. Response headers carry `content-type` (`Formats::Protobuf::CONTENT_TYPE` when the request's `accept` header includes `"application/vnd.google.protobuf"`, else `Formats::Text::CONTENT_TYPE`) and, when the request's `accept-encoding` header includes `"gzip"`, `content-encoding: gzip` with a gzipped body. |

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

## `Rack::Exporter`

Rack middleware that serves metrics at a configurable path, for `config.ru`, Rails, Puma and any other Rack host. Same content negotiation and gzip as `Middleware::Exporter`, over a Rack env instead of a `Protocol::HTTP::Request`.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `app` (positional) | required | The wrapped Rack app. |
| `registry:` | `Fast::Prometheus.registry` | Registry to collect from. |
| `path:` | `"/metrics"` | Request path this middleware serves. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `call(env)` | Rack triple | Serves metrics for a `GET` (`env["REQUEST_METHOD"]`) at `env["PATH_INFO"] == path`; otherwise calls `app.call(env)`. Response headers carry `"content-type"` (`Formats::Protobuf::CONTENT_TYPE` when `env["HTTP_ACCEPT"]` includes `"application/vnd.google.protobuf"`, else `Formats::Text::CONTENT_TYPE`) and, when `env["HTTP_ACCEPT_ENCODING"]` includes `"gzip"`, `"content-encoding" => "gzip"` with a gzipped body. |

## `Rack::Instrumentation`

Rack middleware that records RED metrics for every request, for `config.ru`, Rails, Puma and any other Rack host.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `app` (positional) | required | The wrapped Rack app. |
| `registry:` | `Fast::Prometheus.registry` | Registry the metrics are registered on. |
| `native:` | `false` | When `true`, the duration metric is a `NativeHistogram` instead of a `Histogram`. |
| `prefix:` | `"http_server"` | Prefix for both metric names. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `call(env)` | Rack triple | Times and calls `app.call(env)`, then records it with `method: env["REQUEST_METHOD"]` and the returned status as a String. On `app.call` raising, records the request with `status: "500"` and re-raises the original exception. |

Metric names, types and labels are the same as `Middleware::Instrumentation` (above); a metric already registered under either name on the same registry is reused by whichever surface runs second, not re-registered.
