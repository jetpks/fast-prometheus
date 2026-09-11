# Reference: registry and metrics

## `Fast::Prometheus` module functions

Module-level default registry, lazily constructed at most once.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `.registry` | `Registry` | Builds and memoizes a `Registry` on first call; subsequent calls read the memoized instance without locking. |
| `.registry=(registry)` | `registry` | Replaces the module-level default registry. |

## `Registry`

Holds a collection of metrics by name and produces immutable snapshots.

Constructor

`Registry.new` takes no arguments.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `register(metric)` | `metric` | Raises `DuplicateMetric` if a metric with the same name is already registered. |
| `unregister(name)` | the removed `Metric`, or `nil` | Removes a metric by name. |
| `get(name)` | `Metric` or `nil` | Looks up a metric by name. |
| `fetch_or_register(name) { ... }` | `Metric` | Returns the metric already registered under `name`; else runs the block (inside the registry lock) and registers its result. Raises `ArgumentError` if the block's metric name does not equal `name`. |
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
| `name` (positional) | required | Metric name; must match `/\A[a-zA-Z_:][a-zA-Z0-9_:]*\z/`, else raises `InvalidMetricName`. |
| `docstring:` | required | Non-empty description string; else raises `ArgumentError`. |
| `labels:` | `[]` | Declared label names; each must match `/\A[a-zA-Z_][a-zA-Z0-9_]*\z/` and not start with `__`, else raises `InvalidLabelName`. |
| `preset_labels:` | `{}` | Labels already bound; used internally by `with_labels`. Keys not in `labels:` raise `InvalidLabelSet`. |
| `store:` | `nil` | Internal `Store` to share; used internally by `with_labels`. |

Methods

| Signature | Returns | Notes |
|---|---|---|
| `name` | `Symbol`/`String` | Attribute reader. |
| `docstring` | `String` | Attribute reader. |
| `label_names` | `Array` | Attribute reader. |
| `preset_labels` | `Hash` | Attribute reader. |
| `get(labels: {})` | `Float` | `0.0` for an unobserved series. Overridden by slot-based subclasses (`Histogram`, `Summary`, `NativeHistogram`) to return the slot or `nil`. |
| `type` | — | Raises `NotImplementedError`; every subclass overrides. |
| `with_labels(**labels)` | new instance of the same class | Pre-binds labels for a hot-path metric; shares the parent's store. Raises `InvalidLabelSet` for an unknown label key. |
| `values` | `Hash{Hash => value}` | Every series' value keyed by its label hash. |
| `synchronize { ... }` | block's return value | Runs the block exclusively with respect to every other mutation or read of this metric's store, including `with_labels` children. Reentrant on the same thread. |

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

## `Histogram`

Samples observations into configurable buckets, plus running sum and count. `type` is `:histogram`.

Constructor

| Keyword | Default | Meaning |
|---|---|---|
| `name` (positional) | required | See `Metric`. |
| `docstring:` | required | See `Metric`. |
| `labels:` | `[]` | See `Metric`; `:le` is reserved and raises `InvalidLabelName`. |
| `preset_labels:` | `{}` | See `Metric`. |
| `buckets:` | `Histogram::DEFAULT_BUCKETS` | Upper bounds, ascending; raises `ArgumentError` if empty, non-`Numeric`, or not strictly ascending. |
| `store:` | `nil` | See `Metric`. |

`DEFAULT_BUCKETS` is `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]`.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `observe(value, labels: {})` | unspecified | Records one observation. `duration.observe(0.042, labels: { method: "GET" })` |
| `cumulative_buckets(labels: {})` | `Array<[Float, Integer]>` or `nil` | Per-series cumulative bucket counts, ending with `[Float::INFINITY, count]`; `nil` if the series has no observations. |
| `get(labels: {})` | `Histogram::HistogramSlot` or `nil` | The slot for a label set. |
| `sum(labels: {})` | `Float` or `nil` | Sum of observed values for a series. |
| `count(labels: {})` | `Integer` or `nil` | Count of observed values for a series. |
| `buckets` | `Array<Numeric>` | Attribute reader — the configured upper bounds. |
| `.linear_buckets(start:, width:, count:)` | `Array<Float>` | `count` buckets starting at `start`, each `width` apart. |
| `.exponential_buckets(start:, factor:, count:)` | `Array<Float>` | `count` buckets starting at `start`, each `factor`× the last. Raises `ArgumentError` unless `start > 0`, `factor > 1`, `count >= 1`. |

## `Summary`

Accumulates observations as sum + count per label set, with no quantile computation. `type` is `:summary`.

Constructor: same keywords as `Metric`; `:quantile` is a reserved label name and raises `InvalidLabelName`.

Methods

| Signature | Returns | Notes |
|---|---|---|
| `observe(value, labels: {})` | unspecified | Records one observation. `latency.observe(0.037, labels: { method: "GET" })` |
| `get(labels: {})` | `Summary::Value` or `nil` | The slot (`sum`, `count`) for a label set. |

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
| `observe(value, labels: {})` | `nil` | `native.observe(0.042, labels: { method: "GET" })`. Never raises. `NaN` counts toward `sum`/`count` only; `±Infinity` clamps into the max bucket index (`2**31 - 1`) on the matching side. |
| `get(labels: {})` | `NativeHistogram::Slot` or `nil` | The slot for a label set. |
| `schema` | `Integer` | Attribute reader — the metric's configured schema (not per-series; a series' live schema can be lower after downscaling). |
| `zero_threshold` | `Float` | Attribute reader. |
| `max_buckets` | `Integer` | Attribute reader. |

## `Snapshot`, `MetricSnapshot`, and series value shapes

Immutable, deep-frozen `Data` types returned by `Registry#collect`. Never constructed by application code directly except via `.of`.

| Type | Fields | Notes |
|---|---|---|
| `Snapshot` | `metrics`, `taken_at` | `.of(metrics)` builds one from an `Array<Metric>`; `taken_at` is `Time.now` at build time. |
| `MetricSnapshot` | `name`, `docstring`, `type`, `label_names`, `series` | `.of(metric)` builds one from a live `Metric`, entirely under that metric's lock, so no series is observed mid-mutation. |
| `Series` | `labels`, `value` | One label set and its value; `value`'s shape depends on the metric type. |
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
| `InvalidLabelName` | A label name fails `Metric::LABEL_NAME`, starts with `__`, or is reserved (`:le` on `Histogram`, `:quantile` on `Summary`). |
| `InvalidLabelSet` | A label set has an unknown key, a preset label not in the declared labels, or is missing a required label at resolution time. |
| `DuplicateMetric` | `Registry#register` is called with a name already registered. |
