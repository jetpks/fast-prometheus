# Benchmarks

`benchmark-ips` comparisons, single process, Ruby 4.0.5 on Apple M4 Max
(arm64-darwin25), locked implementation, run against the 0.1.0 release tree:

```
Warming up --------------------------------------
                counter labels (fast)   143.077k i/100ms
   counter labels (prometheus-client)   111.151k i/100ms
                 counter bound (fast)   198.984k i/100ms
    counter bound (prometheus-client)   193.794k i/100ms
             histogram observe (fast)   171.635k i/100ms
histogram observe (prometheus-client)    56.715k i/100ms
      native histogram observe (fast)   136.286k i/100ms
Calculating -------------------------------------
                counter labels (fast)      1.445M (± 1.7%) i/s  (692.11 ns/i) -      3.005M in   2.079533s
   counter labels (prometheus-client)      1.116M (± 1.6%) i/s  (895.88 ns/i) -      2.334M in   2.091132s
                 counter bound (fast)      1.996M (± 1.4%) i/s  (500.91 ns/i) -      4.179M in   2.093135s
    counter bound (prometheus-client)      1.927M (± 1.2%) i/s  (519.07 ns/i) -      3.876M in   2.011872s
             histogram observe (fast)      1.715M (± 1.5%) i/s  (583.10 ns/i) -      3.433M in   2.001607s
histogram observe (prometheus-client)    566.414k (± 1.8%) i/s    (1.77 μs/i) -      1.134M in   2.002598s
      native histogram observe (fast)      1.348M (± 1.7%) i/s  (741.58 ns/i) -      2.726M in   2.021331s

Comparison:
                 counter bound (fast):  1996366.2 i/s
    counter bound (prometheus-client):  1926504.3 i/s - 1.04x  slower
             histogram observe (fast):  1714972.0 i/s - 1.16x  slower
                counter labels (fast):  1444851.8 i/s - 1.38x  slower
      native histogram observe (fast):  1348477.8 i/s - 1.48x  slower
   counter labels (prometheus-client):  1116223.7 i/s - 1.79x  slower
histogram observe (prometheus-client):   566414.2 i/s - 3.52x  slower
```

## Reproducing

```bash
BENCH_QUICK=1 bundle exec ruby benchmark/observe.rb   # quick pass
bundle exec ruby benchmark/observe.rb                 # full run
```

## Key takeaways

- Bound counter (fast) is on par with prometheus-client's bound counter (1.04x)
- Classic histogram observe is **3.0x** faster (1.71M vs 566K i/s)
- Native histogram observe runs at **1.35M i/s** with no prometheus-client equivalent

## The cost of locking

Every number above is the locked implementation — the one this gem ships. Measured against
an unlocked control build on the same machine (`BENCH_QUICK=1`, single process: counter
bound 2.45M i/s, counter labels 1.67M, histogram 2.01M, native histogram 1.56M), the locked
numbers land at roughly 81–87% of control across these operations — the price of the
guarantees in [Concurrency model](concurrency.md). The project's floor is 60% of control on
the same machine; every row here clears it with margin.
