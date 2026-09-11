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
   to run step 2 from ahead of the first request — start the metrics server lazily instead,
   from inside the app's own request handling, guarded so it only runs once:

   ```ruby
   metrics_started = false

   app = Protocol::HTTP::Middleware.for do |request|
     unless metrics_started
       metrics_started = true
       Async::HTTP::Server.new(metrics_app, metrics_bound, protocol: metrics_endpoint.protocol, scheme: metrics_endpoint.scheme).run
     end

     # ... handle request
   end
   ```

   This still works because the request handler is already running inside the reactor's fiber:
   `#run` just schedules the accept-loop task on that same reactor and returns, so it doesn't
   delay the request that triggered it. Under `--threaded`, each thread runs its own reactor and
   would each try to bind the same metrics port on their own first request — start the metrics
   server once, outside any per-thread middleware block, rather than lazily, if you're running
   `--threaded` (see [Concurrency model](../explanation/concurrency.md)).

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
