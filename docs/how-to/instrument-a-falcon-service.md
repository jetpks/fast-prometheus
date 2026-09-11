# How to instrument a falcon.rb service

Run the Falcon-native `Protocol::HTTP` middleware — `Middleware::Instrumentation` and
`Middleware::Exporter` — from a `falcon.rb` service definition, with no Rack layer between the
request and the handler. You need Falcon and fast-prometheus (a `Gemfile` with `gem "falcon"`,
`gem "traces"`, `gem "fast-prometheus"` — see [the tutorial](../tutorials/falcon-app.md) step 1
for why `traces` is needed) and a working directory to run from.

## Steps

1. Create `falcon.rb`:

   ```ruby
   # frozen_string_literal: true

   require "falcon"
   require "falcon/environment/server"
   require "async/service"
   require "fast/prometheus/middleware/instrumentation"
   require "fast/prometheus/middleware/exporter"

   service "falcon-service" do
     include Falcon::Environment::Server

     url "http://localhost:9395"
     count 2

     middleware do
       app = Protocol::HTTP::Middleware.for do |request|
         case request.path
         when "/"
           Protocol::HTTP::Response[200, {}, ["hello"]]
         when "/work"
           Protocol::HTTP::Response[200, {}, ["did work"]]
         else
           Protocol::HTTP::Response[404, {}, ["not found"]]
         end
       end

       app = Fast::Prometheus::Middleware::Instrumentation.new(app, native: true)
       Fast::Prometheus::Middleware::Exporter.new(app)
     end
   end
   ```

   Same two routes and the same two middleware as [the Falcon tutorial](../tutorials/falcon-app.md),
   wired directly onto `Protocol::HTTP` instead of through a Rack `config.ru`. `require
   "falcon/environment/server"` is needed explicitly here — `falcon host`'s CLI loads it for
   you, but a plain `ruby` script driving `Async::Service::Controller` directly (step 3) does
   not.

2. Run it with `falcon host`, Falcon's deployment command:

   ```console
   $ bundle exec falcon host
   ```

   `falcon host` always runs services under the best forked container available
   (`Async::Container::Forked` on any platform with `fork`) — one process per `count`, so a
   scrape only ever sees one of the two (see [Concurrency model](../explanation/concurrency.md)'s
   `--forked` section). The container class shows up in the log once the process is asked to
   stop:

   ```
   {"subject":"Async::Container::Forked","message":"Stopping container...","timeout":true}
   ```

   ```console
   $ curl http://localhost:9395/
   hello
   $ curl http://localhost:9395/metrics
   # HELP http_server_requests_total Total HTTP requests
   # TYPE http_server_requests_total counter
   http_server_requests_total{method="GET",status="200"} 9.0
   ```

3. Run the same `falcon.rb` under a threaded container instead, with this five-line launcher
   saved as `threaded.rb`:

   ```ruby
   require "falcon"
   require "async/service"
   require "async/container"
   configuration = Async::Service::Configuration.load(["falcon.rb"])
   Async::Service::Controller.run(configuration, container_class: Async::Container::Threaded)
   ```

   ```console
   $ bundle exec ruby threaded.rb
   ```

   Now `count 2` runs as two threads inside one process sharing one `Fast::Prometheus.registry`
   instead of two forked processes — the log names the container class the same way:

   ```
   {"subject":"Async::Container::Threaded","message":"Stopping container...","timeout":true}
   ```

   and a scrape after traffic on both threads sees all of it in one place:

   ```console
   $ curl http://localhost:9395/metrics
   # HELP http_server_requests_total Total HTTP requests
   # TYPE http_server_requests_total counter
   http_server_requests_total{method="GET",status="200"} 10.0
   ```

   On SIGTERM the accept loops log `IOError: stream closed in another thread` warnings —
   `async-service` stops the services before the container itself; cosmetic, not a failure.

## Result

The same `falcon.rb`, and the same two middleware, run correctly under both of Falcon's
container models: forked (Falcon's default, one registry per process) and threaded (one
registry shared by every thread, the shape [Concurrency model](../explanation/concurrency.md)
is built for).

See [Reference: exposition formats and HTTP middleware](../reference/exposition.md) for
`Middleware::Instrumentation` and `Middleware::Exporter`'s full constructor keywords and
behavior.
