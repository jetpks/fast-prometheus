# Concurrency model

fast-prometheus is safe by default: a `Registry` — including the module-level
`Fast::Prometheus.registry` — can be shared across every OS thread of a process and across
every fiber within a thread, with no locking the caller has to do. That default is a design
decision, not the only possible one: "it's just not that useful to be zero-lock at this
point in time in the ruby ecosystem" (see [Design: why a new gem](design.md)). This
document is about the cost and shape of that default; see
[Benchmarks](benchmarks.md) for what it costs in numbers.

## The guarantees

Four properties hold for every metric type and for the registry, under any mix of
concurrent threads and fibers:

- **No lost updates.** If N threads each perform k successful mutations against the same
  series, the series' total reflects all N·k of them.
- **No cross-thread exceptions.** No metric or registry call raises because of a concurrent
  call on another thread — in particular, inserting a new label series never raises while a
  snapshot is iterating the store.
- **Snapshot consistency.** Every series in a snapshot is observed at one point in time: a
  histogram's `+Inf` bucket equals its count and its buckets sum to that count; a native
  histogram's `positive + negative + zero_count` equals its count.
- **Registry integrity.** Concurrent `register`/`unregister`/`collect` never corrupts the
  registry's metric table or registers the same name twice, and the module-level default
  registry is constructed at most once regardless of how many threads first call
  `Fast::Prometheus.registry`.

## What's actually locked

Each metric owns one `Store`, and the store owns the lock (`lib/fast/prometheus/store.rb`) —
a `Monitor`, not a plain `Mutex`, because it's reentrant: a thread already holding it (for
example, `Metric#synchronize` driving `MetricSnapshot.of`, or `Histogram#sum`, `#count` and
`#cumulative_buckets` calling `get`, which locks again) can enter it again without deadlocking itself.
`Metric#with_labels` returns a new metric object that shares its parent's `Store`, so a bound
counter from `with_labels` and its unbound parent are mutually exclusive on the same lock —
mutating one blocks a concurrent mutation or read of the other. Every mutation
(`increment`, `set`, `observe`) and every read (`get`, `values`, the snapshot build) is one
critical section on that lock.

The registry itself has a second, separate lock (a plain `Mutex`) guarding its name-to-metric
table. `register`, `unregister`, `get`, and `metrics` each take it for the duration of the
table operation only. `collect` takes it just long enough to copy the current list of
registered metrics (`Registry#metrics`); building each metric's own snapshot happens after
that lock is released, under that metric's own store lock. So `collect` never holds the
registry lock across more than one metric — a slow or contended metric snapshot can't stall
`register`/`unregister` calls on other metrics, and a snapshot never observes a metric that's
mid-registration.

`Metric#synchronize { ... }` exposes this same per-metric lock to callers: the block runs
atomically with respect to every other mutation or read of that metric's store, including
mutations from any of its `with_labels`-bound children.

## Scheduler-aware locks

Both `Monitor` and `Mutex` integrate with `Fiber.scheduler`: a fiber that contends a lock
yields control to its thread's reactor instead of blocking the OS thread. Other fibers on
that thread keep making progress while the contending fiber waits its turn. This is what
makes the locking here compatible with the fiber-per-request model async servers use —
locking a metric doesn't stall the reactor, only the fiber that's waiting.

## `--threaded` vs `--forked`

Falcon `--threaded --count N` runs one process with N OS threads, each running its own Async
reactor; the module-level `Fast::Prometheus.registry`, or any `Registry` built at boot, is
shared by all of them, and the guarantees above are exactly what makes that safe. Falcon
`--forked` instead runs N independent processes, each with its own registry populated from
its own requests — a scrape of any one process sees only that process's metrics.
Aggregating counts across forked processes (e.g. summing before exposition, or relying on
Prometheus's own cross-target aggregation) is out of scope for this gem; a `--forked`
deployment needs its own strategy for that.
