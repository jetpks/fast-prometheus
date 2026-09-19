# Benchmarks

Three views of the cost of this gem, all single process on Ruby 4.0.7 with fast-protowire
0.3.0, Apple M4 Max (arm64-darwin), the locked implementation: how fast an observation is,
how much an observation allocates, and what one scrape of a large registry costs to render, in time
and in garbage, against `google-protobuf` and `prometheus-client`.

## Scraping

`benchmark/exposition.rb` is a suite of four views over one registry shape: 36,000 series
on a 12-label counter plus a labeled histogram, gauge and summary, the shape of a
production registry. Timed columns are the mean of ten calls with GC on; allocation
columns are one call with GC off, so they are the call's whole footprint. `BENCH_QUICK=1`
runs a 5,000-series version in under a minute; `SERIES=n` picks the main size.

### Scrape, end to end

`Middleware::Exporter` served by `Async::HTTP` on a loopback socket and scraped over one
keep-alive HTTP/1.1 connection, as Prometheus does, in each content variant it negotiates:

| content | on the wire | s/scrape |
|---|---|---|
| text | 11.2 MB | 0.084 |
| text, gzip | 1.2 MB | 0.115 |
| protobuf | 11.8 MB | 0.173 |
| protobuf, gzip | 1.1 MB | 0.21 |

Text is the cheaper wire format here by about 2x; protobuf is what Prometheus needs for
native histograms and exemplars, and its cost is the encoder, below. gzip adds 30–40 ms
and takes the body from 11–12 MB to about 1 MB.

### Where a scrape goes

Each stage on its own, then the two `Exposition.render` calls the middleware makes:

| stage | output | s/call | objects/call | malloc MiB/call |
|---|---|---|---|---|
| Registry#collect | 0.0 MB | 0.001 | 328 | 2.0 |
| Formats::Text.render | 11.2 MB | 0.066 | 36,565 | 16.0 |
| Formats::Protobuf.render | 11.8 MB | 0.159 | 24 | 7.6 |
| Zlib.gzip (text) | 1.2 MB | 0.046 | 8 | 0.9 |
| Zlib.gzip (protobuf) | 1.1 MB | 0.047 | 8 | 1.4 |
| Exposition.render, text + gzip | 1.2 MB | 0.116 | 36,916 | 18.9 |
| Exposition.render, protobuf + gzip | 1.1 MB | 0.208 | 397 | 11.0 |

Taking the snapshot (`Registry#collect`) is one copy of each metric's store under its
lock: 1 ms, a few hundred objects and 2 MiB, whatever the label count. The text renderer
allocates one String per sample line (the value's `to_s`) and nothing per label. The
protobuf renderer writes each series' bytes straight to the wire from the snapshot, no
message objects, each series and each family written in place behind a length prefix
filled in afterwards, so a render of any size is a few dozen objects: the family headers
(and on Ruby 3.4+, fast-protowire 0.3.0 appends each label's tag, size and text in one
call). Beyond the body itself it mallocs a few MiB, the output String growing. gzip is
`Zlib.gzip` on the finished body.

### By registry size

The two renderers and `prometheus-client`'s text formatter over the same series:

| series | fast text s | objects | fast protobuf s | objects | prometheus-client text s | objects |
|---|---|---|---|---|---|---|
| 1,000 | 0.002 | 1,564 | 0.005 | 23 | 0.006 | 73,728 |
| 10,000 | 0.02 | 10,564 | 0.045 | 23 | 0.057 | 676,728 |
| 36,000 | 0.066 | 36,564 | 0.16 | 23 | 0.212 | 2,418,728 |
| 100,000 | 0.186 | 100,564 | 0.438 | 23 | 0.681 | 6,706,728 |

Every column is linear in series. `prometheus-client`'s formatter allocates about 67
objects per series (it builds each line and each label pair as its own String) against
one here, and the gap in time widens with size as the garbage collector's share grows:
3.2x at 36,000 series, 3.7x at 100,000.

### Against google-protobuf

The two `google-protobuf` encoders this gem shipped before
[fast-protowire](https://github.com/jetpks/fast-protowire), producing the same bytes:
0.2.0 built every series into one `MetricFamily` and encoded it once; the streamed fix
encoded one `Metric` at a time. Live arenas are the `google-protobuf` messages still alive
after the render, one native arena each.

| encoder | s/render | objects/render | malloc MiB/render | live arenas after | GC runs (10 renders) | GC ms |
|---|---|---|---|---|---|---|
| fast-prometheus protobuf (fast-protowire) | 0.158 | 24 | 3.4 | 0 | 1 minor + 0 major | 1 |
| google-protobuf, one Metric at a time | 0.376 | 3,494,272 | 237.9 | 504,424 | 46 minor + 1 major | 902 |
| google-protobuf, whole family (0.2.0) | 0.473 | 3,422,107 | 232.3 | 504,424 | 42 minor + 9 major | 1753 |

Both build a message object per label pair and per series, and each message is a native
arena plus a Ruby wrapper registered in a process-wide object cache. A scrape of 36,000
series is 504,424 messages, three and a half million Ruby objects and a quarter gigabyte
of malloc before the 12 MB body exists, and the garbage collector then spends more time
on that garbage (0.9 to 1.8 s per ten scrapes) than the encoder spent producing it. That
is the problem this gem's protobuf path exists to remove; see [Design](design.md).

## Observing

`benchmark/observe.rb`: every mutation and read a metric offers, against `prometheus-client`'s
equivalent where it has one. Iterations per second are `benchmark-ips` (2 s per row after
1 s of warmup); objects per call are `GC.stat`, exact, with the label Hash built once
outside the loop so the count is the library's, not the caller's literal. "Bound" holds the
`with_labels` metric for the loop, the way an instrumented hot path does.

| operation | fast-prometheus i/s | prometheus-client i/s | fast / client | fast-prometheus objects/call | prometheus-client objects/call |
|---|---|---|---|---|---|
| counter increment, labels | 1.29M | 1.03M | 1.25x | 1.0 | 5.0 |
| counter increment, bound | 2.52M | 1.73M | 1.46x | 0.0 | 1.0 |
| counter get, labels | 1.81M | 1.36M | 1.34x | 1.0 | 5.0 |
| gauge set, labels | 1.72M | 1.25M | 1.38x | 1.0 | 5.0 |
| gauge set, bound | 3.84M | 2.63M | 1.46x | 0.0 | 1.0 |
| gauge increment, labels | 1.29M | 1.03M | 1.26x | 1.0 | 5.0 |
| histogram observe, labels | 1.53M | 0.53M | 2.87x | 1.0 | 8.0 |
| histogram observe, bound | 2.35M | 0.63M | 3.73x | 0.0 | 5.0 |
| summary observe, labels | 1.9M | 0.61M | 3.11x | 1.0 | 10.0 |
| native histogram observe, labels | 1.2M | — | — | 1.0 | — |
| native histogram observe, bound | 1.64M | — | — | 0.0 | — |

A bound or unlabeled call allocates nothing: the default label set is one shared frozen
Hash and the store lock is taken with `yield` rather than a captured block. A labeled
call allocates its resolved key, the Array of label values that indexes the store.
`test/fast/prometheus/allocations.rb` holds these budgets, and the per-series budgets
for `collect` and both renderers, so they cannot regress unnoticed.

A labeled call also normalizes each value to valid UTF-8 as it resolves the key (see
[Normalization](../reference/metrics.md#normalization)), which is what the labeled rows
lost against 0.3.2's published numbers — 6–13% fewer iterations per second, with the
bound rows unchanged and every allocation column the same.

## Reproducing

```bash
BENCH_QUICK=1 bundle exec ruby benchmark/observe.rb      # quick pass
bundle exec ruby benchmark/observe.rb                    # full run
bundle exec ruby benchmark/exposition.rb                 # 36k-series scrape, ~2 minutes
```

## Key takeaways

- A protobuf scrape renders in **24 objects** where `google-protobuf` needed 3.5 million
  and 504k native arenas; 2.4–3.0x faster, with 1 ms of GC per ten renders against 0.9–1.8 s.
- The text renderer allocates **66x fewer objects** than `prometheus-client`'s for the
  same body, and renders it 3.2x faster at 36,000 series, 3.7x at 100,000.
- A full text scrape of 36,000 series over HTTP is 84 ms, 115 ms with gzip; protobuf 173 ms
  and 210 ms.
- Bound counter and gauge writes are **1.46x** faster than `prometheus-client`'s and allocate
  nothing; histogram observe is **2.9x** faster and summary observe **3.1x**.
- Native histogram observe runs at **1.2M i/s** with no `prometheus-client` equivalent.

