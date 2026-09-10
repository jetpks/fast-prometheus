# Benchmarks

`benchmark-ips` comparisons, single process, Ruby 4.0.5 on Apple M4 Pro
(arm64-darwin25), locked implementation:

```
Warming up --------------------------------------
                counter labels (fast)   140.435k i/100ms
   counter labels (prometheus-client)   106.893k i/100ms
                 counter bound (fast)   201.717k i/100ms
    counter bound (prometheus-client)   193.579k i/100ms
             histogram observe (fast)   173.954k i/100ms
histogram observe (prometheus-client)    56.747k i/100ms
      native histogram observe (fast)   135.968k i/100ms
Calculating -------------------------------------
                counter labels (fast)      1.446M (± 1.8%) i/s  (691.74 ns/i) -      2.949M in   2.040039s
   counter labels (prometheus-client)      1.113M (± 1.6%) i/s  (898.51 ns/i) -      2.245M in   2.016944s
                 counter bound (fast)      2.000M (± 1.6%) i/s  (499.99 ns/i) -      4.034M in   2.017128s
    counter bound (prometheus-client)      1.938M (± 1.0%) i/s  (516.10 ns/i) -      4.065M in   2.098010s
             histogram observe (fast)      1.723M (± 1.3%) i/s  (580.29 ns/i) -      3.479M in   2.018880s
histogram observe (prometheus-client)    564.954k (± 1.4%) i/s    (1.77 μs/i) -      1.135M in   2.008907s
      native histogram observe (fast)      1.363M (± 1.4%) i/s  (733.88 ns/i) -      2.855M in   2.095457s

Comparison:
                 counter bound (fast):  2000041.6 i/s
    counter bound (prometheus-client):  1937626.1 i/s - 1.03x  slower
             histogram observe (fast):  1723272.3 i/s - 1.16x  slower
                counter labels (fast):  1445626.8 i/s - 1.38x  slower
      native histogram observe (fast):  1362627.8 i/s - 1.47x  slower
   counter labels (prometheus-client):  1112947.6 i/s - 1.80x  slower
histogram observe (prometheus-client):   564954.0 i/s - 3.54x  slower
```

## Reproducing

```bash
BENCH_QUICK=1 bundle exec ruby benchmark/observe.rb   # quick pass
bundle exec ruby benchmark/observe.rb                 # full run
```

## Key takeaways

- Bound counter (fast) is on par with prometheus-client's bound counter (1.03x)
- Classic histogram observe is **3.0x** faster (1.72M vs 565K i/s)
- Native histogram observe runs at **1.36M i/s** with no prometheus-client equivalent

## The cost of locking

Every number above is the locked implementation — the one this gem ships. Measured against
an unlocked control build on the same machine (`BENCH_QUICK=1`, single process: counter
bound 2.45M i/s, counter labels 1.67M, histogram 2.01M, native histogram 1.56M), the locked
numbers land at roughly 81–88% of control across these operations — the price of the
guarantees in [Concurrency model](concurrency.md). The project's floor is 60% of control on
the same machine; every row here clears it with margin.
