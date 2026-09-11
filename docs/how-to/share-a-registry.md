# How to share one registry across boot paths

Let several independent boot paths (middleware setup, a background job runner, a console
initializer) construct the same metric on one shared `Registry` without racing each other
into a `DuplicateMetric` error. You need a `Registry` already reachable from each boot path
(commonly `Fast::Prometheus.registry`).

## Steps

1. In each boot path, wrap the metric construction in `fetch_or_register`:

   ```ruby
   requests = Fast::Prometheus.registry.fetch_or_register(:http_requests_total) do
     Fast::Prometheus::Counter.new(:http_requests_total, docstring: "Total HTTP requests", labels: %i[method path])
   end
   ```

   The first boot path to run registers the metric; every later call for the same name
   returns that same instance instead of registering a duplicate.

2. Build the metric in the block with `Counter.new` (or the matching metric class), never
   with a registry convenience constructor (`registry.counter`, `registry.histogram`, ...).
   `fetch_or_register` already holds the registry lock while it runs the block, and
   `registry.counter` would try to take that same lock again to call `register` — Ruby's
   `Mutex` isn't reentrant, so it raises `ThreadError` (recursive locking).

3. Name the block's metric after the argument you passed to `fetch_or_register` — if it
   doesn't match, `fetch_or_register` raises `ArgumentError` rather than registering the
   mismatch silently. Keep the block identical (or extract it into a shared constant) across
   every boot path that registers the metric, so the type and labels stay consistent
   regardless of which boot path runs first.

## Result

Every boot path ends up with a reference to the one registered metric, regardless of
which one ran first or how many ran concurrently.

`Middleware::Instrumentation` uses `fetch_or_register` internally for its two metrics
(`<prefix>_requests_total`, `<prefix>_request_duration_seconds`), so pre-registering a metric
under those names on the registry you pass it is supported, as long as your metric's label
names match what the middleware records (`method`, `status`).

See [Reference: registry and metrics](../reference/metrics.md) for `Registry#fetch_or_register`'s
full signature and the `ArgumentError` it raises when a block's metric name doesn't match the
requested name, and [Reference: exposition formats and HTTP middleware](../reference/exposition.md)
for `Middleware::Instrumentation`'s metric names and labels.
