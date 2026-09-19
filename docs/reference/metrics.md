# Reference: registry and metrics

## `Fast::Prometheus` module functions

Module-level default registry, lazily constructed at most once.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `.registry` | `Registry` | Builds and memoizes a `Registry` on first call; subsequent calls read the memoized instance without locking. |
| `.registry=(registry)` | `registry` | Replaces the module-level default registry; synchronized with the reader. |

## `Registry`

Holds a collection of metrics by name and produces immutable snapshots.

Constructor

`Registry.new` takes no arguments.

Methods

`name` accepts a `String` or a `Symbol` on every method below; it's normalized to a `Symbol` before lookup.

| Signature | Returns | Notes |
|---|---|---|
| `register(metric)` | `metric` | Raises `DuplicateMetric` if a metric with the same name is already registered, regardless of which form (`String`/`Symbol`) either name was given in. |
| `unregister(name)` | the removed `Metric`, or `nil` | Removes a metric by name. |
| `get(name)` | `Metric` or `nil` | Looks up a metric by name. |
| `exist?(name)` | `true`/`false` | Whether a metric is registered under `name`. |
| `fetch_or_register(name) { ... }` | `Metric` | Returns the metric already registered under `name`; else runs the block (inside the registry lock) and registers its result. Raises `ArgumentError` if the block's metric name does not equal `name` (compared as `Symbol`s). |
| `metrics` | `Array<Metric>` | Registered metrics, insertion order. |
| `counter(name, **kwargs)` | `Counter` | Builds a `Counter`, registers it, and returns it. |
| `gauge(name, **kwargs)` | `Gauge` | Builds a `Gauge`, registers it, and returns it. |
| `histogram(name, **kwargs)` | `Histogram` | Builds a `Histogram`, registers it, and returns it. |
| `summary(name, **kwargs)` | `Summary` | Builds a `Summary`, registers it, and returns it. |
| `native_histogram(name, **kwargs)` | `NativeHistogram` | Builds a `NativeHistogram`, registers it, and returns it. |
| `collect` | `Snapshot` | Snapshots every registered metric; see [`Snapshot`](#snapshot). |

## `Metric`

Abstract base class for every metric type; subclasses implement `#type` and their own mutators.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `name` (positional) | required | Metric name; accepts a `String` or a `Symbol`, validated against `/\A[a-zA-Z_:][a-zA-Z0-9_:]*\z/`, else raises `InvalidMetricName`. Stored as a `Symbol`. |
| `docstring:` | required | Non-empty description string; else raises `ArgumentError`. Normalized to valid UTF-8 — see Normalization below. |
| `labels:` | `[]` | Declared label names, accepted as `String`s or `Symbol`s and stored as `Symbol`s. Each must match `/\A[a-zA-Z_][a-zA-Z0-9_]*\z/` and not start with `__`; two names that normalize to the same `Symbol` (`%i[x x]`, `[:x, "x"]`) are a duplicate. Any of these raises `InvalidLabelName`. The Array is copied and frozen. |
| `preset_labels:` | `{}` | Labels already bound; used internally by `with_labels`. Keys are normalized like `labels:`; keys not in `labels:` raise `InvalidLabelSet`. Values are normalized and frozen. |
| `store:` | `nil` | Internal `Store` to share; used internally by `with_labels`. |

Construction seeds a zero-valued series when the metric is fully bound — see Seeding below.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `name` | `Symbol` | Attribute reader. |
| `docstring` | `String` | Attribute reader. |
| `labels` | `Array<Symbol>` | Declared label names, frozen. Mutating the Array passed to `labels:` after construction changes nothing. |
| `preset_labels` | `Hash` | Attribute reader. |
| `get(labels: {})` | `Float` | `0.0` for an unobserved series; never creates one. Overridden by slot-based subclasses (`Histogram`, `Summary`, `NativeHistogram`) to return their own shape — see each type below. |
| `init_label_set(labels)` | unspecified | Resolves `labels` like any mutator (raises `InvalidLabelSet` for an unknown or missing label) and, under the store lock, creates that series at the type's zero value only if it's absent. Idempotent: never resets a series that already has observations. |
| `type` | — | Raises `NotImplementedError`; every subclass overrides. |
| `with_labels(**labels)` | new instance of the same class | Pre-binds labels for a hot-path metric; shares the parent's store. Raises `InvalidLabelSet` for an unknown label key. Seeds its own series on creation if the result is fully bound. |
| `values` | `Hash{Hash => value}` | Every series' value keyed by its label hash; shape depends on the metric type — see each type below. |
| `snapshot_values` | `Hash{Array => value}` | Every series' value in its frozen snapshot shape (see [`Snapshot`, `MetricSnapshot`, and series value shapes](#snapshot-metricsnapshot-and-series-value-shapes)), keyed by the series' label values in `labels` order (the store's own key): the store copied and its slots frozen under the lock, one Hash however many series. `Counter`/`Gauge` use the already-frozen `Float`; `Histogram`, `Summary`, and `NativeHistogram` use `HistogramValue`, `SummaryValue`, and `NativeHistogramValue` respectively — the seam `MetricSnapshot.of` uses. |
| `synchronize { ... }` | block's return value | Runs the block exclusively with respect to every other mutation or read of this metric's store, including `with_labels` children. Reentrant on the same thread. |

### Normalization

Label names, label values and docstrings are normalized once, at the boundary where they
enter the metric's store, so every reader downstream — `values`, `Registry#collect`, text and
protobuf exposition, OTLP — sees one shape and no renderer can meet a mixed or invalid
encoding.

**Names** are `Symbol`s. `labels: ["method"]` and `labels: [:method]` declare the same metric,
`labels` reports `[:method]` for both, and observe-time keys are `Symbol`s either way:
`increment(labels: { method: "GET" })`. A `String` key at observe time is an unknown label and
raises `InvalidLabelSet`.

**Values** (per-call `labels:`, `preset_labels:`, `with_labels`) are stored as valid UTF-8
bytes. A non-`String` is converted with `to_s` first, then:

| Input | Stored as |
|---|---|
| ASCII-only, any encoding | the caller's own object, unchanged, encoding tag and all — ASCII bytes are already valid UTF-8, so `"GET".b` from a Rack env, `200.to_s`'s `US-ASCII` and a UTF-8 literal all cost nothing and all render the same bytes |
| UTF-8, valid | the caller's own object, unchanged — the hot path allocates nothing for it |
| UTF-8, invalid | scrubbed (`String#scrub`); each invalid byte sequence becomes `U+FFFD` |
| `BINARY` (`ASCII-8BIT`) | reinterpreted as UTF-8 bytes and scrubbed, never transcoded — `BINARY` is bytes, not a charset, so `"na\xefve".b` becomes `"na�ve"` |
| any other encoding | transcoded to UTF-8 with invalid and undefined bytes replaced — the same bytes tagged `ISO-8859-1` become `"naïve"` |

**Docstrings** get the same treatment at construction.

Two consequences worth stating plainly: bytes that are not valid UTF-8 are lossy — they are
replaced, not preserved — and the same bytes can normalize differently depending on the
encoding they arrive tagged with, because that tag is the only thing saying what they mean.

### Seeding

A metric seeds one zero-valued series at construction when it's fully bound: no declared
labels, or `preset_labels:` covers every declared label. A `with_labels` call that fully
binds its parent's remaining labels seeds its own series the same way. A partially-bound
metric (declared labels not fully covered by `preset_labels:`) seeds nothing until a mutator
or `init_label_set` is called with a complete label set.

A seeded series appears in `values`, in `Registry#collect`, and in text/protobuf exposition
at its type's zero value (`0.0` for `Counter`/`Gauge`, all-zero buckets/sum/count for
`Histogram`, zero count/sum for `Summary`, a zero-count `NativeHistogramValue` for
`NativeHistogram`) — e.g. a freshly seeded `Counter` renders `requests_total 0.0`. Zero-valued `increment`/`decrement`
remain no-ops; they don't need to seed a series that already exists. `get` never creates a
series — reading an absent one just returns the type's zero shape.

## `Counter`

A monotonically increasing metric. `type` is `:counter`.

Constructor: same keywords as `Metric`.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `increment(by: 1, labels: {})` | unspecified | Raises `ArgumentError` unless `by` is a non-negative `Numeric`. A `by` of `0` is a no-op. `requests.increment(by: 5, labels: { method: "POST", path: "/api" })` |

## `Gauge`

A value that can go up or down. `type` is `:gauge`.

Constructor: same keywords as `Metric`.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `set(value, labels: {})` | unspecified | Raises `ArgumentError` unless `value` is `Numeric`. `temperature.set(72.5, labels: { core: "0" })` |
| `increment(by: 1, labels: {})` | unspecified | Raises `ArgumentError` unless `by` is `Numeric`. A `by` of `0` is a no-op. `temperature.increment(labels: { core: "0" })` |
| `decrement(by: 1, labels: {})` | unspecified | Raises `ArgumentError` unless `by` is `Numeric`. A `by` of `0` is a no-op. `temperature.decrement(by: 5, labels: { core: "0" })` |
| `set_to_current_time(labels: {})` | unspecified | `set(Time.now.to_f, labels: labels)`. `last_heartbeat.set_to_current_time` |

## `Histogram`

Samples observations into configurable buckets, plus running sum and count. `type` is `:histogram`.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `name` (positional) | required | See `Metric`. |
| `docstring:` | required | See `Metric`. |
| `labels:` | `[]` | See `Metric`; `:le` is reserved — as is `"le"`, which normalizes to it — and raises `InvalidLabelName`. |
| `preset_labels:` | `{}` | See `Metric`. |
| `buckets:` | `Histogram::DEFAULT_BUCKETS` | Upper bounds, ascending; raises `ArgumentError` if empty, non-`Numeric`, non-finite, or not strictly ascending. Every bound is finite: the `+Inf` bucket is implicit and always rendered, so an explicit `Float::INFINITY` (or a `Float::NAN`) bound is a mistake, not a second `+Inf`. Copied and frozen at construction. |
| `store:` | `nil` | See `Metric`. |

`DEFAULT_BUCKETS` is `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]`.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `observe(value, labels: {})` | unspecified | Records one observation. `duration.observe(0.042, labels: { method: "GET" })` |
| `cumulative_buckets(labels: {})` | `Array<[Float, Integer]>` | Per-series cumulative bucket counts as frozen pairs in a frozen Array, ending with `[Float::INFINITY, count]`; all-zero counts for an unobserved series — never `nil`. |
| `get(labels: {})` | `Hash` | A fresh `Hash` per call, built under the store lock: each bucket boundary's `to_s` in ascending order, then `"+Inf"`, then `"sum"`; bucket/`"+Inf"` values are cumulative `Integer` counts, `"sum"` is the `Float` sum. All-zero for an unobserved series — mutating the returned `Hash` never affects the metric. Same shape as `Prometheus::Client::Histogram#get`. |
| `sum(labels: {})` | `Float` | Sum of observed values for a series; `0.0` for an unobserved series. |
| `count(labels: {})` | `Integer` | Count of observed values for a series; `0` for an unobserved series. |
| `buckets` | `Array<Numeric>` | Attribute reader — the configured upper bounds, frozen. Mutating the Array passed to `buckets:` after construction changes nothing. |
| `.linear_buckets(start:, width:, count:)` | `Array<Float>` | `count` buckets starting at `start`, each `width` apart. |
| `.exponential_buckets(start:, factor:, count:)` | `Array<Float>` | `count` buckets starting at `start`, each `factor`× the last. Raises `ArgumentError` unless `start > 0`, `factor > 1`, `count >= 1`. |

`values` returns `{ label_hash => get(labels: label_hash)'s shape }` for every series.

## `Summary`

Accumulates observations as sum + count per label set, with no quantile computation. `type` is `:summary`.

Constructor: same keywords as `Metric`; `:quantile` — and `"quantile"`, which normalizes to it — is a reserved label name and raises `InvalidLabelName`.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `observe(value, labels: {})` | unspecified | Records one observation. `latency.observe(0.037, labels: { method: "GET" })` |
| `get(labels: {})` | `Hash` | `{ "count" => Integer, "sum" => Float }`, in that key order. `{ "count" => 0, "sum" => 0.0 }` for an unobserved series. Mutating the returned `Hash` never affects the metric. |

`values` returns `{ label_hash => get(labels: label_hash)'s shape }` for every series.

## `NativeHistogram`

Sparse, base-2 exponential histogram covering the full float range. `type` is `:native_histogram`.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `name` (positional) | required | See `Metric`. |
| `docstring:` | required | See `Metric`. |
| `labels:` | `[]` | See `Metric`. |
| `preset_labels:` | `{}` | See `Metric`. |
| `schema:` | `3` | Integer in `-4..8`; higher is finer-grained. Raises `ArgumentError` outside that range. |
| `zero_threshold:` | `2.0**-128` | `Float >= 0`; observations with `abs <= zero_threshold` count as the zero bucket. Raises `ArgumentError` if not a non-negative `Float`. |
| `max_buckets:` | `160` | Positive `Integer`; the slot halves its resolution (`schema -= 1`) and merges adjacent buckets whenever `positive.size + negative.size` exceeds this, down to `schema > -4`. Raises `ArgumentError` unless a positive `Integer`. |
| `store:` | `nil` | See `Metric`. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `observe(value, labels: {})` | `nil` | `native.observe(0.042, labels: { method: "GET" })`. Raises `ArgumentError` unless `value` is `Numeric`; never raises for a `Numeric`, however odd. `NaN` counts toward `sum`/`count` only; `±Infinity` clamps into the max bucket index (`2**31 - 1`) on the matching side. |
| `get(labels: {})` | `NativeHistogramValue` | A frozen `NativeHistogramValue` (see [`Snapshot`, `MetricSnapshot`, and series value shapes](#snapshot-metricsnapshot-and-series-value-shapes) below) built under the store lock; the zero-valued value at the metric's `schema`/`zero_threshold` for an unobserved series. |
| `schema` | `Integer` | Attribute reader — the metric's configured schema (not per-series; a series' live schema can be lower after downscaling). |
| `zero_threshold` | `Float` | Attribute reader. |
| `max_buckets` | `Integer` | Attribute reader. |

`values` returns `{ label_hash => NativeHistogramValue }` for every series.

## `Snapshot`, `MetricSnapshot`, and series value shapes

Immutable, frozen value types returned by `Registry#collect`: `Snapshot` and `MetricSnapshot` are `Data`; the value shapes are `Struct`s frozen where they are built, because `Data.new` costs two extra objects per instance and a scrape builds one per histogram, summary or native histogram series. Never constructed by application code directly except via `.of`.

| Type | Fields | Notes |
|---|---|---|
| `Snapshot` | `metrics`, `taken_at` | `.of(metrics)` builds one from an `Array<Metric>`; `taken_at` is `Time.now` at build time. |
| `MetricSnapshot` | `name`, `docstring`, `type`, `label_names`, `series` | `.of(metric)` builds one from a live `Metric`. `series` is a frozen `Hash` from each series' label values (an `Array` in `label_names` order) to its value: the metric's store copied under its lock, so no series is observed mid-mutation. `labels(values)` turns one key back into a `{name => value}` Hash. |
| `HistogramValue` | `sum`, `count`, `cumulative_buckets` | `value` for a `:histogram` series. |
| `SummaryValue` | `sum`, `count` | `value` for a `:summary` series. |
| `NativeHistogramValue` | `schema`, `zero_threshold`, `zero_count`, `sum`, `count`, `positive_buckets`, `negative_buckets` | `value` for a `:native_histogram` series. |

`:counter` and `:gauge` series carry a plain `Float` as `value`.

## Errors

All defined in `errors.rb`, all subclasses of `Fast::Prometheus::Error` (itself a `StandardError`).

| Class | Raised when |
|---|---|
| `Error` | Base class; never raised directly. |
| `InvalidMetricName` | A metric name fails `Metric::METRIC_NAME`. |
| `InvalidLabelName` | A label name fails `Metric::LABEL_NAME`, starts with `__`, duplicates another declared name once both are normalized to `Symbol`s, or is reserved (`:le` on `Histogram`, `:quantile` on `Summary`). |
| `InvalidLabelSet` | A label set has an unknown key, a preset label not in the declared labels, or is missing a required label at resolution time. |
| `DuplicateMetric` | `Registry#register` is called with a name already registered. |
