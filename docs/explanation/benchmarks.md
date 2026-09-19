# Benchmarks

Three views of the cost of this gem, all single process on Ruby 4.0.7, Apple M4 Max
(arm64-darwin), the locked implementation: how fast an observation is, how much an
observation allocates, and what one scrape of a large registry costs to render, in time
and in garbage, against `google-protobuf` and `prometheus-client`.

## Rendering a scrape

`benchmark/exposition.rb`: a registry of 36,000 series on a 12-label counter plus a
labeled histogram, gauge and summary (production shape), rendered ten times each way.
The allocation columns are one render with GC disabled, so they are the render's whole
footprint: Ruby objects, bytes malloc'd (including `google-protobuf`'s native arenas),
and the `google-protobuf` messages still alive afterwards, one arena each. The GC columns
are what the process paid over the ten timed renders.

| renderer | output | s/render | objects/render | malloc MiB/render | live arenas after | GC runs (10 renders) | GC ms |
|---|---|---|---|---|---|---|---|
| fast-prometheus text | 11.2 MB | 0.071 | 36,594 | 16.0 | 0 | 1 minor + 1 major | 30 |
| fast-prometheus protobuf (fast-protowire) | 11.8 MB | 0.198 | 183 | 32.0 | 0 | 5 minor + 2 major | 62 |
| google-protobuf, one Metric at a time | 11.8 MB | 0.409 | 3,530,294 | 242.3 | 504,424 | 41 minor + 4 major | 1043 |
| google-protobuf, whole family (0.2.0) | 11.8 MB | 0.501 | 3,422,107 | 232.5 | 504,424 | 44 minor + 9 major | 1858 |
| prometheus-client text | 11.2 MB | 0.194 | 2,418,768 | 35.0 | 0 | 10 minor + 0 major | 201 |

The two `google-protobuf` rows are the encoders this gem shipped before
[fast-protowire](https://github.com/jetpks/fast-protowire): 0.2.0 built every series into
one `MetricFamily` and encoded it once; the streamed fix encoded one `Metric` at a time.
Both build a message object per label pair and per series, and each message is a native
arena plus a Ruby wrapper registered in a process-wide object cache. A scrape of 36,000
series is 504,424 messages, three and a half million Ruby objects and a quarter gigabyte
of malloc before the 12 MB body exists, and the garbage collector then spends more time on that
garbage (1.0 to 1.9 s per ten scrapes) than the encoder spent producing it. That is the
problem this gem's protobuf path exists to remove; see
[Design](design.md).

The fast-prometheus protobuf renderer writes each series' bytes straight to the wire
from the snapshot, no message objects, so a render of any size is a few hundred objects:
the family headers and one scratch buffer. What remains of its 32 MiB is the body and
the label strings it copies into the buffer. The text renderer allocates one String per
sample line (the value's `to_s`) and nothing per label; `prometheus-client`'s text
formatter allocates about 67 per series.

Taking the snapshot the renderers read (`Registry#collect`) is not in the table because
it is now the same for every row that uses it: at 36,000 series it is one copy of each
metric's store under its lock, 1 ms, 342 objects and 2 MiB, whatever the label count.

`SERIES=5000 bundle exec ruby benchmark/exposition.rb` runs a smaller registry;
`BENCH_QUICK=1` shortens the timed runs.

## Observing

`benchmark-ips` comparisons against `prometheus-client`, run against the tree at the
0.3.0 release:

```
Calculating -------------------------------------
                counter labels (fast)      1.346M (± 2.5%) i/s  (742.72 ns/i) -      2.777M in   2.062677s
   counter labels (prometheus-client)      1.046M (± 3.3%) i/s  (956.18 ns/i) -      2.110M in   2.017397s
                 counter bound (fast)      2.705M (± 3.1%) i/s  (369.70 ns/i) -      5.452M in   2.015478s
    counter bound (prometheus-client)      1.782M (± 3.6%) i/s  (561.15 ns/i) -      3.592M in   2.015506s
             histogram observe (fast)      1.549M (± 2.9%) i/s  (645.75 ns/i) -      3.122M in   2.016210s
histogram observe (prometheus-client)    517.494k (± 3.4%) i/s    (1.93 μs/i) -      1.037M in   2.002998s
      native histogram observe (fast)      1.256M (± 2.7%) i/s  (796.37 ns/i) -      2.571M in   2.047132s

Comparison:
                 counter bound (fast):  2704887.9 i/s
    counter bound (prometheus-client):  1782063.7 i/s - 1.52x  slower
             histogram observe (fast):  1548598.6 i/s - 1.75x  slower
                counter labels (fast):  1346399.4 i/s - 2.01x  slower
      native histogram observe (fast):  1255698.2 i/s - 2.15x  slower
   counter labels (prometheus-client):  1045827.4 i/s - 2.59x  slower
histogram observe (prometheus-client):   517494.3 i/s - 5.23x  slower
```

And what each call allocates, in Ruby objects, with the labels Hash built once outside
the loop so the count is the library's, not the caller's literal:

```
Allocations per call (objects):
  counter labels (fast)                    1.0
  counter labels (prometheus-client)       5.0
  counter bound (fast)                     0.0
  counter bound (prometheus-client)        1.0
  histogram observe (fast)                 1.0
  histogram observe (prometheus-client)    8.0
  native histogram observe (fast)          1.0
```

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

- A protobuf scrape renders in **183 objects** where `google-protobuf` needed 3.5 million
  and 504k native arenas; 2.1–2.5x faster, with 62 ms of GC per ten renders against 1.0–1.9 s.
- The text renderer allocates **66x fewer objects** than `prometheus-client`'s for the
  same body, and renders it 2.7x faster.
- Bound counter increments are **1.52x** faster than `prometheus-client`'s and allocate
  nothing; classic histogram observe is **3.0x** faster.
- Native histogram observe runs at **1.26M i/s** with no `prometheus-client` equivalent.

