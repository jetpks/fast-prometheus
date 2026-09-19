# Benchmarks

Three views of the cost of this gem, all single process on Ruby 4.0.7, Apple M4 Max
(arm64-darwin), the locked implementation: how fast an observation is, how much an
observation allocates, and what one scrape of a large registry costs to render, in time
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
| text | 11.2 MB | 0.082 |
| text, gzip | 1.2 MB | 0.113 |
| protobuf | 11.8 MB | 0.198 |
| protobuf, gzip | 1.1 MB | 0.235 |

Text is the cheaper wire format here by about 2.4x; protobuf is what Prometheus needs for
native histograms and exemplars, and its cost is the encoder, below. gzip adds 30–45 ms
and takes the body from 11–12 MB to about 1 MB.

### Where a scrape goes

Each stage on its own, then the two `Exposition.render` calls the middleware makes:

| stage | output | s/call | objects/call | malloc MiB/call |
|---|---|---|---|---|
| Registry#collect | 0.0 MB | 0.001 | 328 | 2.0 |
| Formats::Text.render | 11.2 MB | 0.064 | 36,563 | 16.0 |
| Formats::Protobuf.render | 11.8 MB | 0.182 | 29 | 32.0 |
| Zlib.gzip (text) | 1.2 MB | 0.044 | 8 | 0.0 |
| Zlib.gzip (protobuf) | 1.1 MB | 0.046 | 8 | 0.0 |
| Exposition.render, text + gzip | 1.2 MB | 0.11 | 36,899 | 14.1 |
| Exposition.render, protobuf + gzip | 1.1 MB | 0.232 | 365 | 30.6 |

Taking the snapshot (`Registry#collect`) is one copy of each metric's store under its
lock: 1 ms, a few hundred objects and 2 MiB, whatever the label count. The text renderer
allocates one String per sample line (the value's `to_s`) and nothing per label. The
protobuf renderer writes each series' bytes straight to the wire from the snapshot, no
message objects, so a render of any size is a few dozen objects: the family headers and
one scratch buffer. What remains of its 32 MiB is the body and the label strings copied
into the buffer. gzip is `Zlib.gzip` on the finished body.

### By registry size

The two renderers and `prometheus-client`'s text formatter over the same series:

| series | fast text s | objects | fast protobuf s | objects | prometheus-client text s | objects |
|---|---|---|---|---|---|---|
| 1,000 | 0.002 | 1,562 | 0.005 | 28 | 0.005 | 73,728 |
| 10,000 | 0.019 | 10,562 | 0.05 | 28 | 0.053 | 676,728 |
| 36,000 | 0.064 | 36,562 | 0.181 | 28 | 0.203 | 2,418,728 |
| 100,000 | 0.18 | 100,562 | 0.499 | 28 | 0.691 | 6,706,728 |

Every column is linear in series. `prometheus-client`'s formatter allocates about 67
objects per series (it builds each line and each label pair as its own String) against
one here, and the gap in time widens with size as the garbage collector's share grows:
2.6x at 1,000 series, 3.8x at 100,000.

### Against google-protobuf

The two `google-protobuf` encoders this gem shipped before
[fast-protowire](https://github.com/jetpks/fast-protowire), producing the same bytes:
0.2.0 built every series into one `MetricFamily` and encoded it once; the streamed fix
encoded one `Metric` at a time. Live arenas are the `google-protobuf` messages still alive
after the render, one native arena each.

| encoder | s/render | objects/render | malloc MiB/render | live arenas after | GC runs (10 renders) | GC ms |
|---|---|---|---|---|---|---|
| fast-prometheus protobuf (fast-protowire) | 0.182 | 29 | 32.0 | 0 | 7 minor + 0 major | 8 |
| google-protobuf, one Metric at a time | 0.382 | 3,530,293 | 238.8 | 504,424 | 44 minor + 1 major | 909 |
| google-protobuf, whole family (0.2.0) | 0.461 | 3,422,107 | 228.0 | 504,424 | 45 minor + 8 major | 1643 |

Both build a message object per label pair and per series, and each message is a native
arena plus a Ruby wrapper registered in a process-wide object cache. A scrape of 36,000
series is 504,424 messages, three and a half million Ruby objects and a quarter gigabyte
of malloc before the 12 MB body exists, and the garbage collector then spends more time
on that garbage (0.9 to 1.6 s per ten scrapes) than the encoder spent producing it. That
is the problem this gem's protobuf path exists to remove; see [Design](design.md).

## Observing

`benchmark/observe.rb`: every mutation and read a metric offers, against `prometheus-client`'s
equivalent where it has one. Iterations per second are `benchmark-ips` (2 s per row after
1 s of warmup); objects per call are `GC.stat`, exact, with the label Hash built once
outside the loop so the count is the library's, not the caller's literal. "Bound" holds the
`with_labels` metric for the loop, the way an instrumented hot path does.

| operation | fast-prometheus i/s | prometheus-client i/s | fast / client | fast-prometheus objects/call | prometheus-client objects/call |
|---|---|---|---|---|---|
| counter increment, labels | 1.42M | 1.07M | 1.32x | 1.0 | 5.0 |
| counter increment, bound | 2.58M | 1.78M | 1.45x | 0.0 | 1.0 |
| counter get, labels | 2.06M | 1.39M | 1.48x | 1.0 | 5.0 |
| gauge set, labels | 1.93M | 1.35M | 1.43x | 1.0 | 5.0 |
| gauge set, bound | 4.03M | 2.78M | 1.45x | 0.0 | 1.0 |
| gauge increment, labels | 1.43M | 1.08M | 1.32x | 1.0 | 5.0 |
| histogram observe, labels | 1.65M | 0.54M | 3.06x | 1.0 | 8.0 |
| histogram observe, bound | 2.38M | 0.64M | 3.71x | 0.0 | 5.0 |
| summary observe, labels | 2.03M | 0.62M | 3.25x | 1.0 | 10.0 |
| native histogram observe, labels | 1.32M | — | — | 1.0 | — |
| native histogram observe, bound | 1.75M | — | — | 0.0 | — |

A bound or unlabeled call allocates nothing: the default label set is one shared frozen
Hash and the store lock is taken with `yield` rather than a captured block. A labeled
call allocates its resolved key, the Array of label values that indexes the store.
`test/fast/prometheus/allocations.rb` holds these budgets, and the per-series budgets
for `collect` and both renderers, so they cannot regress unnoticed.

## Reproducing

```bash
BENCH_QUICK=1 bundle exec ruby benchmark/observe.rb      # quick pass
bundle exec ruby benchmark/observe.rb                    # full run
bundle exec ruby benchmark/exposition.rb                 # 36k-series scrape, ~2 minutes
```

## Key takeaways

- A protobuf scrape renders in **29 objects** where `google-protobuf` needed 3.5 million
  and 504k native arenas; 2.1–2.5x faster, with 8 ms of GC per ten renders against 0.9–1.6 s.
- The text renderer allocates **66x fewer objects** than `prometheus-client`'s for the
  same body, and renders it 3.2x faster at 36,000 series, 3.8x at 100,000.
- A full text scrape of 36,000 series over HTTP is 82 ms, 113 ms with gzip; protobuf 198 ms
  and 235 ms.
- Bound counter and gauge writes are **1.45x** faster than `prometheus-client`'s and allocate
  nothing; histogram observe is **3.1x** faster and summary observe **3.3x**.
- Native histogram observe runs at **1.32M i/s** with no `prometheus-client` equivalent.

