# Benchmarks

Three views of the cost of this gem, all single process on Ruby 4.0.5, Apple M4 Max
(arm64-darwin25), the locked implementation: how fast an observation is, how much an
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
| fast-prometheus text | 11.2 MB | 0.065 | 36,595 | 16.0 | 0 | 1 minor + 1 major | 25 |
| fast-prometheus protobuf (fast-protowire) | 11.8 MB | 0.191 | 187 | 32.0 | 0 | 6 minor + 3 major | 94 |
| google-protobuf, one Metric at a time | 11.8 MB | 0.378 | 3,026,113 | 247.8 | 504,424 | 37 minor + 4 major | 920 |
| google-protobuf, whole family (0.2.0) | 11.8 MB | 0.469 | 2,953,983 | 241.3 | 504,424 | 43 minor + 9 major | 1686 |
| prometheus-client text | 11.2 MB | 0.184 | 2,418,769 | 35.0 | 0 | 10 minor + 0 major | 196 |

The two `google-protobuf` rows are the encoders this gem shipped before
[fast-protowire](https://github.com/jetpks/fast-protowire): 0.2.0 built every series into
one `MetricFamily` and encoded it once; the streamed fix encoded one `Metric` at a time.
Both build a message object per label pair and per series, and each message is a native
arena plus a Ruby wrapper registered in a process-wide object cache. A scrape of 36,000
series is 504,424 messages, three million Ruby objects and a quarter gigabyte of malloc
before the 12 MB body exists, and the garbage collector then spends more time on that
garbage (0.9 to 1.7 s per ten scrapes) than the encoder spent producing it. That is the
problem this gem's protobuf path exists to remove; see
[Design](design.md).

The fast-prometheus protobuf renderer writes each series' bytes straight to the wire
from the snapshot, no message objects, so a render of any size is a few hundred objects:
the family headers and one scratch buffer. What remains of its 32 MiB is the body and
the label strings it copies into the buffer. The text renderer allocates one String per
sample line (the value's `to_s`) and nothing per label; `prometheus-client`'s text
formatter allocates about 67 per series.

`SERIES=5000 bundle exec ruby benchmark/exposition.rb` runs a smaller registry;
`BENCH_QUICK=1` shortens the timed runs.

## Observing

`benchmark-ips` comparisons against `prometheus-client`, run against the tree at the
0.3.0 release:

```
Calculating -------------------------------------
                counter labels (fast)      1.401M (± 1.6%) i/s  (713.77 ns/i) -      2.803M in   2.000771s
   counter labels (prometheus-client)      1.086M (± 1.7%) i/s  (920.58 ns/i) -      2.176M in   2.003635s
                 counter bound (fast)      2.710M (± 1.4%) i/s  (369.04 ns/i) -      5.683M in   2.097398s
    counter bound (prometheus-client)      1.856M (± 1.6%) i/s  (538.78 ns/i) -      3.745M in   2.017584s
             histogram observe (fast)      1.662M (± 1.6%) i/s  (601.59 ns/i) -      3.440M in   2.069549s
histogram observe (prometheus-client)    547.595k (± 1.5%) i/s    (1.83 μs/i) -      1.097M in   2.003742s
      native histogram observe (fast)      1.328M (± 1.5%) i/s  (752.95 ns/i) -      2.675M in   2.014460s

Comparison:
                 counter bound (fast):  2709747.5 i/s
    counter bound (prometheus-client):  1856051.6 i/s - 1.46x  slower
             histogram observe (fast):  1662273.8 i/s - 1.63x  slower
                counter labels (fast):  1401019.9 i/s - 1.93x  slower
      native histogram observe (fast):  1328107.8 i/s - 2.04x  slower
   counter labels (prometheus-client):  1086275.7 i/s - 2.49x  slower
histogram observe (prometheus-client):   547595.4 i/s - 4.95x  slower
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

- A protobuf scrape renders in **187 objects** where `google-protobuf` needed 3 million
  and 504k native arenas; 2.0–2.5x faster, and a tenth of the GC time.
- The text renderer allocates **66x fewer objects** than `prometheus-client`'s for the
  same body, and renders it 2.8x faster.
- Bound counter increments are **1.46x** faster than `prometheus-client`'s and allocate
  nothing; classic histogram observe is **3.0x** faster.
- Native histogram observe runs at **1.33M i/s** with no `prometheus-client` equivalent.

## The cost of locking

Every number above is the locked implementation — the one this gem ships. Measured at
0.1.0 against an unlocked control build on the same machine (`BENCH_QUICK=1`, single
process: counter bound 2.45M i/s, counter labels 1.67M, histogram 2.01M, native histogram
1.56M), the locked numbers landed at roughly 81–87% of control across these operations —
the price of the guarantees in [Concurrency model](concurrency.md). The project's floor is
60% of control on the same machine. Since then the lock is taken without allocating a Proc
per call, which is why the bound counter now clears that old control outright; the
remaining gap is the lock itself.
