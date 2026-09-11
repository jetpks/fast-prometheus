# How to serve metrics on a separate port

Expose `/metrics` on its own port, separate from the app's port — for example so the app port
can sit behind auth or a load balancer that never sees `/metrics`. You need fast-prometheus and
`async-http` (already one of its runtime dependencies).

## Steps

1. Build a metrics-only app: `Middleware::Exporter` wrapping `Protocol::HTTP::Middleware::NotFound`,
   so nothing except `/metrics` answers on this port:

   ```ruby
   metrics_app = Fast::Prometheus::Middleware::Exporter.new(Protocol::HTTP::Middleware::NotFound)
   ```

2. Serve it from its own `Async::HTTP::Endpoint`, started from an `Async` block at boot,
   alongside the app's own server:

   ```ruby
   require "async"
   require "async/http/endpoint"
   require "async/http/server"

   app_endpoint = Async::HTTP::Endpoint.parse("http://localhost:9398")
   metrics_endpoint = Async::HTTP::Endpoint.parse("http://localhost:9399")

   Async do |task|
     app_bound = app_endpoint.bound
     metrics_bound = metrics_endpoint.bound

     Async::HTTP::Server.new(app, app_bound, protocol: app_endpoint.protocol, scheme: app_endpoint.scheme).run
     Async::HTTP::Server.new(metrics_app, metrics_bound, protocol: metrics_endpoint.protocol, scheme: metrics_endpoint.scheme).run

     task.children.each(&:wait)
   end
   ```

   `#run` (`Async::HTTP::Server#run`) wraps its accept loop in its own `Async` task and returns
   immediately, so starting both servers in the same block doesn't block either of them on the
   other.

3. When Falcon owns the reactor for you (`falcon.rb` / `falcon serve`), there's no boot hook
   to run step 2 from ahead of the first request. Falcon evaluates `config.ru` — and, for a
   `falcon.rb` service, its `middleware do ... end` block — once per worker, whether a worker
   is a thread (`--threaded`) or a process (`--forked`), so a lazy start guarded by a local
   like `metrics_started` runs once per worker rather than once per server. Start the metrics
   server lazily, from inside the app's own request handling, and bind its endpoint with
   `reuse_port: true` so every worker's own first-request bind of that port succeeds instead
   of racing every other worker for it:

   ```ruby
   require "async/http/endpoint"
   require "async/http/server"
   require "fast/prometheus/rack/instrumentation"

   metrics_endpoint = Async::HTTP::Endpoint.parse("http://localhost:9399", reuse_port: true)
   metrics_started = false

   app = Fast::Prometheus::Rack::Instrumentation.new(lambda do |env|
     unless metrics_started
       metrics_started = true
       Async::HTTP::Server.new(metrics_app, metrics_endpoint.bound, protocol: metrics_endpoint.protocol, scheme: metrics_endpoint.scheme).run
     end

     # ... handle request
   end)

   run app
   ```

   This is the Rack form, for `config.ru` under `falcon serve`: `Rack::Instrumentation` wraps
   the app, and nothing wraps the app in `Rack::Exporter` or `Middleware::Exporter` — the app
   port never serves `/metrics` in this recipe, only the app's own routes (and its own 404 for
   anything else, including `/metrics`). `#run` still just schedules the accept-loop task on
   the current reactor and returns, same as step 2, so starting it from inside a request
   doesn't delay that request.

   Under `--threaded`, every thread's lazy start binds the same metrics port (`reuse_port:
   true` lets all of them succeed) and every thread mutates the same module-level registry, so
   a scrape of the metrics port sees the complete count across every thread. Under
   `--forked`, each worker is its own process with its own registry, so a scrape only sees
   that one process's requests — see [Concurrency model](../explanation/concurrency.md)'s
   `--threaded` vs `--forked` section.

4. Verify:

   ```console
   $ curl localhost:9399/metrics
   # HELP http_server_requests_total Total HTTP requests
   # TYPE http_server_requests_total counter
   http_server_requests_total{method="GET",status="200"} 3.0
   http_server_requests_total{method="GET",status="404"} 1.0
   $ curl -o /dev/null -w '%{http_code}\n' localhost:9398/metrics
   404
   ```

## Result

The app port and the metrics port are independent `Async::HTTP::Server`s sharing one registry
and one reactor; the app port never serves `/metrics`.

See [Reference: exposition formats and HTTP middleware](../reference/exposition.md) for
`Middleware::Exporter`.
