# Reference: exposition formats and HTTP middleware

## `Formats::Text`

Renders a `Snapshot` as Prometheus text exposition format 0.0.4. Consumes only `Snapshot` value objects, never live metrics.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `.render(snapshot)` | `String` | Content type `Formats::Text::CONTENT_TYPE` (`"text/plain; version=0.0.4; charset=utf-8"`). The body is always a UTF-8-tagged, valid String, matching that `charset`: the buffer starts in UTF-8 and the snapshot's docstrings and label values were normalized where they entered the store (see [Normalization](metrics.md#normalization)), so no combination of inputs can produce a mixed or invalid encoding here. Metrics of type `:native_histogram` are omitted entirely — no `HELP`/`TYPE` lines, no series. |

## `Formats::Protobuf`

Renders a `Snapshot` as delimited Prometheus protobuf exposition (`io.prometheus.client.MetricFamily`). Each series' bytes are written straight from the snapshot with `Fast::Protowire::Wire`, no message objects; the output is byte-identical to encoding the declared `Formats::Protobuf::Proto` classes (and to `google-protobuf`, which the tests decode it with).

Methods

| Signature | Returns | Notes |
|---|---|---|
| `.render(snapshot)` | `String` | Content type `Formats::Protobuf::CONTENT_TYPE` (`"application/vnd.google.protobuf; proto=io.prometheus.client.MetricFamily; encoding=delimited"`). One length-prefixed (varint) `MetricFamily` frame per metric, concatenated. `:native_histogram` series map to a protobuf `Histogram` with `schema`/`zero_threshold`/`zero_count`/`positive_span`/`positive_delta`/`negative_span`/`negative_delta` set. |

## Negotiation

Both exporters pick the response format and content coding from the request's `Accept` and
`Accept-Encoding` the same way, in `Exposition.render`. Each header is read as an RFC 9110 list:
comma-separated members, each a token with optional `;`-parameters.

| Rule | Effect |
|---|---|
| The token is matched whole and case-insensitively | `APPLICATION/VND.GOOGLE.PROTOBUF` and `GZIP` are recognised; `notgzipping` and `text/plain;foo="application/vnd.google.protobuf"` are not protobuf mentions. |
| Parameters other than `q` are ignored | `application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited` selects protobuf. `encoding=` is not honoured as a request: delimited is the only encoding `Formats::Protobuf` renders. |
| `q=0` is a refusal, an absent `q` is `1` | `gzip;q=0` and `application/vnd.google.protobuf;q=0` are not acceptable. |
| Between `application/vnd.google.protobuf` and `text/plain`, the higher `q` wins; a tie is protobuf | Prometheus' own `Accept` (protobuf at `q=0.7`, text at `q=0.5`) selects protobuf; the reverse selects text. |
| Anything else is no preference | An absent, empty or unparseable header — of any length — selects text with no compression, and never raises. |

Text is the fallback, not a negotiated choice: a request accepting neither format (`application/json`)
is answered with text rather than `406`.

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
| `call(request)` | `Protocol::HTTP::Response` | Serves metrics for a `GET` whose target's path component is `path`; otherwise delegates to the wrapped app. A `Protocol::HTTP` request target carries its query string, so `/metrics?x=1` and `/metrics?` are served (a Prometheus `params:` scrape config produces exactly those), while `/metrics/`, `/METRICS` and `/metricsx` delegate. Response headers carry `content-type` (`Formats::Protobuf::CONTENT_TYPE` or `Formats::Text::CONTENT_TYPE`) and, when gzip is acceptable, `content-encoding: gzip` with a gzipped body — see [Negotiation](#negotiation). |

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

The duration is time to the delegate (or Rack app) returning, not to the last byte of the
response: for a streaming body, that is time-to-headers, and the time spent producing the body
afterwards is not in the observation.

### The `method` label

The `method` label is allowlisted, so the two metrics hold at most ten `method` values whatever
tokens clients send — an HTTP method is any token both `Protocol::HTTP` and Rack accept, and
nothing reclaims a series once it exists.

| Request method | Label value |
|---|---|
| `GET` `HEAD` `POST` `PUT` `DELETE` `CONNECT` `OPTIONS` `TRACE` (RFC 9110), `PATCH` (RFC 5789) | the method itself |
| anything else — `PROPFIND`, `M-SEARCH`, `get` (methods are case-sensitive), a token with a high byte | `_OTHER`, the value OpenTelemetry's HTTP semantic conventions collapse an unrecognised method to |

### Reusing a pre-registered metric

Both metrics are obtained via `registry.fetch_or_register`, so a metric already registered under
either name — by application code, at boot — is reused instead of re-registered, as long as it
declares `labels: %i[method status]`. One declaring anything else raises `InvalidLabelSet` from
the instrumentation's constructor, where the mistaken declaration is, rather than once per
request from inside the app's request path.

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
| `call(env)` | Rack triple | Serves metrics for a `GET` (`env["REQUEST_METHOD"]`) at `env["PATH_INFO"] == path`; otherwise calls `app.call(env)`. `PATH_INFO` never carries the query (it is `env["QUERY_STRING"]`), so `/metrics?x=1` is served. Response headers carry `"content-type"` (`Formats::Protobuf::CONTENT_TYPE` or `Formats::Text::CONTENT_TYPE`, from `env["HTTP_ACCEPT"]`) and, when `env["HTTP_ACCEPT_ENCODING"]` accepts gzip, `"content-encoding" => "gzip"` with a gzipped body — see [Negotiation](#negotiation). |

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
| `call(env)` | Rack triple | Times and calls `app.call(env)`, then records it with `env["REQUEST_METHOD"]` through the `method` allowlist and the returned status as a String. On `app.call` raising, records the request with `status: "500"` and re-raises the original exception. |

Metric names, types, labels, duration semantics and reuse are the same as
`Middleware::Instrumentation` (above); a metric already registered under either name on the same
registry is reused by whichever surface runs second, not re-registered.

An app returning a nil status records `status: ""`: the status is recorded as it is returned, and
an app that returns none is defective — this middleware does not guess one for it.
