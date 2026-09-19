# Native histograms

A classic Prometheus histogram (`Histogram`) requires the operator to choose bucket
boundaries up front, trading resolution for cardinality: too few buckets and
`histogram_quantile` estimates are coarse; too many and every series multiplies the bucket
count. A native histogram (`NativeHistogram`) sidesteps that choice. It's a sparse,
base-2 exponential histogram that covers the full float range without the operator naming a
single boundary.

## Schema and zero threshold

`schema` (an integer from -4 to 8) sets the resolution: each bucket's upper bound is
`base ** index` where `base = 2 ** (2 ** -schema)`, so a higher schema means narrower
buckets and more of them for the same value range. Buckets exist only where observations
land — `NativeHistogram` stores `{index => count}` sparse maps for the positive and negative
sides, not a fixed array, so an application with a narrow value distribution pays for only
the buckets it uses.

Values within `zero_threshold` of zero (a `Float`, default `2.0**-128`) count as the special
zero bucket rather than being placed in the exponential ladder — this avoids the ladder
needing an infinite number of ever-narrower buckets to represent values near zero.

## Downscaling

A histogram's bucket count can still grow unbounded as new distinct values arrive at a fine
schema. `NativeHistogram` bounds this with `max_buckets` (default `160`, counting positive
and negative sides together): whenever an observation pushes the combined bucket count over
that limit, the histogram halves its resolution — it merges each adjacent pair of buckets
into one by decrementing `schema` by 1 and remapping every existing bucket index to
`index / 2` (rounded toward the wider bucket) — and repeats until it's back under the limit
or `schema` bottoms out at -4. This trades resolution for a bounded memory footprint per
series, automatically, without the operator pre-choosing a bucket count. Downscaling is
per label series (`NativeHistogram::Slot`), so one busy series can lose resolution without
affecting its siblings.

## Why protobuf-only

The [Prometheus native histogram spec](https://prometheus.io/docs/specs/native_histograms/)
is explicit that the classic text exposition format was never extended to carry native
histogram data and no such extension is planned — a native histogram carries substantially
more structured data (schema, zero threshold, sparse bucket maps) than the format's flat
`name{labels} value` lines were designed for, and OpenMetrics text support remains a
work in progress upstream. Protobuf's structured, typed encoding is the only exposition
format that currently carries this shape.

`Formats::Text.render` reflects this directly: it skips any metric whose `type` is
`:native_histogram` rather than emitting a lossy approximation. Only
`Formats::Protobuf.render` includes them. `Middleware::Exporter` serves whichever format the
request's `Accept` header negotiates, so a scraper that doesn't ask for protobuf never sees
native histograms even though they're registered — see
[How to scrape native histograms](../how-to/scrape-native-histograms.md) for the scrape
config that asks for it.

## OTLP mapping

`OTLP::Mapper` maps a `:native_histogram` series to OTLP's `ExponentialHistogram` data point
type — the OTLP model's native representation for the same sparse exponential shape, so the
mapping is direct: `schema` becomes OTLP `scale`, `zero_count`/`zero_threshold` carry over
as-is, and the sparse `{index => count}` maps become OTLP's offset + dense bucket-count
arrays.

Two things don't survive the crossing. A `±Inf` observation, which Prometheus keeps by
clamping it into the bucket at `MAX_BUCKET_INDEX`, has no bucket in the OTLP model, and a
NaN, which Prometheus counts without bucketing, has nothing OTLP can count it as. So the
data point carries the series' finite observations only: the clamp bucket is dropped, those
observations are excluded from `count`, and `sum` — an `optional` field there — is omitted
rather than exported as an infinity or a NaN. The Prometheus-side value is unaffected;
`Formats::Protobuf` still exposes every observation.

OTLP's bucket counts are one contiguous array per side where Prometheus' are a sparse map,
so two observations far apart in magnitude would otherwise cost an array as wide as the
distance between them. Beyond 1024 slots the mapper halves the resolution the same way
downscaling does — merging adjacent buckets and reporting the coarser `scale` — until both
sides fit.
