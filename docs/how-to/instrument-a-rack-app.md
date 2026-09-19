# How to instrument a Rack app

Add request metrics and a `/metrics` endpoint to a Rack app — a `config.ru` under `falcon
serve`, a Rails app, or anything hosted by Puma — using
`Fast::Prometheus::Rack::Instrumentation` and `Fast::Prometheus::Rack::Exporter`. You need a
Rack app to add the middleware to.

## Steps

1. Require the two Rack middleware:

   ```ruby
   require "fast/prometheus/rack/instrumentation"
   require "fast/prometheus/rack/exporter"
   ```

2. In `config.ru`, add both `use` lines, `Instrumentation` outermost and `Exporter` ahead of
   any authentication middleware that would otherwise gate `/metrics`:

   ```ruby
   use Fast::Prometheus::Rack::Instrumentation, native: true
   use Fast::Prometheus::Rack::Exporter

   run app
   ```

   `Instrumentation` outermost times the whole stack below it, including `Exporter`; putting
   `Exporter` ahead of an auth middleware means a scraper doesn't need credentials meant for
   the app. This exact pair of `use` lines is what
   [the Falcon tutorial](../tutorials/falcon-app.md) runs and verifies.

3. In a Rails app, add the same two lines to `config/application.rb` instead:

   ```ruby
   config.middleware.use Fast::Prometheus::Rack::Instrumentation, native: true
   config.middleware.use Fast::Prometheus::Rack::Exporter
   ```

   (This step isn't run as part of verifying this page — there's no Rails app in this repo to
   run it against.)

4. Behind Puma, or any other threaded Rack host, no extra step is needed: every thread reaches
   `Fast::Prometheus.registry` by default, and a `Registry` is safe to share across threads —
   see [Concurrency model](../explanation/concurrency.md).

5. Verify:

   ```console
   $ curl localhost:PORT/metrics
   ```

## Result

`/metrics` serves the registry's current snapshot (text by default, protobuf when the request
asks for it), and `http_server_requests_total` / `http_server_request_duration_seconds` grow
with every request the app serves. Their `method` label is allowlisted: a request with a method
outside the RFC 9110 set plus `PATCH` is counted as `method="_OTHER"`, so a client cannot mint
series by inventing methods.

See [Reference: exposition formats and HTTP middleware](../reference/exposition.md) for
`Rack::Exporter` and `Rack::Instrumentation`'s full constructor keywords and behavior.
