# Tutorial: instrument a Falcon app

In this tutorial we build a small [Falcon](https://github.com/socketry/falcon) app, add
request metrics and a native histogram with fast-prometheus, and scrape it with a real
Prometheus server. By the end you'll have a running app, a `/metrics` endpoint, and two
PromQL queries returning data.

You'll need Ruby, Falcon and Prometheus. Falcon 0.55.5 and Prometheus 3.14.0 are used
here; other 0.5x/3.x releases should behave the same.

Work in a new, empty directory for the rest of this tutorial.

## 1. Create the Gemfile

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

gem "falcon", "0.55.5"
gem "traces"
gem "fast-prometheus"
```

Falcon's CLI loads `traces` unconditionally, so add it explicitly even though nothing in
this tutorial calls it directly.

Run `bundle install`.

If you're working against an unreleased checkout of fast-prometheus instead of the
published gem, replace the last line with `gem "fast-prometheus", path:
"/path/to/fast-prometheus"`.

## 2. Create the app

```ruby
# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/middleware/instrumentation"
require "fast/prometheus/middleware/exporter"
require "protocol/http/middleware"
require "protocol/rack/constants"

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
app = Fast::Prometheus::Middleware::Exporter.new(app)

# Falcon's config.ru is a Rack boundary; protocol-rack injects the original
# Protocol::HTTP::Request under this env key so the middleware above can use it directly.
run lambda { |env|
  response = app.call(env[Protocol::Rack::PROTOCOL_HTTP_REQUEST])
  [response.status, response.headers.to_h, response.body]
}
```

The block is a tiny `Protocol::HTTP` app with two routes. `Instrumentation` wraps it to record
request counts and durations (`native: true` records the duration as a native histogram
instead of a classic one); `Exporter` adds the `/metrics` endpoint. Both default to
`Fast::Prometheus.registry`, the module-level registry, so no `registry:` keyword is
needed here.

## 3. Run it

```console
$ bundle exec falcon serve --threaded --count 2 --bind http://localhost:9394
```

`--threaded --count 2` runs two OS threads sharing the module-level registry;
`--bind http://localhost:9394` binds plain HTTP on port 9394 (Falcon's default bind is
`https://localhost:9292`). You should see:

```
Falcon v0.55.5 taking flight! Using Async::Container::Threaded {count: 2, restart: true, health_check_timeout: 30.0}.
- Running on ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +PRISM [arm64-darwin25]
- Binding to: #<Falcon::Endpoint http://localhost:9394/ {}>
- To terminate: Ctrl-C or kill <pid>
- To reload configuration: kill -HUP <pid>
```

Leave it running and open a second terminal for the rest of this tutorial.

## 4. Generate some traffic and look at `/metrics`

```console
$ curl http://localhost:9394/
hello
$ curl http://localhost:9394/work
did work
```

Hit both routes a few more times, then scrape the app yourself:

```console
$ curl http://localhost:9394/metrics
# HELP http_server_requests_total Total HTTP requests
# TYPE http_server_requests_total counter
http_server_requests_total{method="GET",status="200"} 13.0
```

Only the counter shows up — the native histogram (`http_server_request_duration_seconds`)
is missing. The text exposition format never carries native histograms; they're protobuf-only.
See [Native histograms](../explanation/native-histograms.md) for why, and the next section
for how to see it anyway.

## 5. Scrape it with Prometheus

Create a scrape config that asks for the protobuf format:

```yaml
global:
  scrape_interval: 2s

scrape_configs:
  - job_name: "falcon_app"
    scrape_native_histograms: true
    static_configs:
      - targets: ["localhost:9394"]
```

Run Prometheus against it:

```console
$ prometheus --config.file=prometheus.yml
```

Wait a few seconds for the first scrapes, then query the counter:

```console
$ curl 'http://localhost:9090/api/v1/query?query=http_server_requests_total'
```

```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "http_server_requests_total",
          "instance": "localhost:9394",
          "job": "falcon_app",
          "method": "GET",
          "status": "200"
        },
        "value": [1789083757.055, "13"]
      }
    ]
  }
}
```

And the native histogram:

```console
$ curl 'http://localhost:9090/api/v1/query?query=http_server_request_duration_seconds'
```

```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "http_server_request_duration_seconds",
          "instance": "localhost:9394",
          "job": "falcon_app",
          "method": "GET",
          "status": "200"
        },
        "histogram": [
          1789083757.171,
          {
            "count": "13",
            "sum": "0.00005199981387704611",
            "buckets": [
              [0, "0.0000019073486328125", "0.0000020799784329705385", "3"],
              [0, "0.000002941533709350473", "0.000003207765255942209", "6"],
              [0, "0.000003814697265625", "0.000004159956865941077", "2"],
              [0, "0.0000069961856323598564", "0.00000762939453125", "1"],
              [0, "0.000012831061023768835", "0.000013992371264719713", "1"]
            ]
          }
        ]
      }
    ]
  }
}
```

`scrape_native_histograms: true` is what makes the difference: it tells Prometheus to
negotiate the protobuf exposition format for this job, which is the one format that
carries native histograms.

## What you built

A Falcon app, sharing one `fast-prometheus` registry across its threads, exporting a
request counter and a native histogram of request durations, scraped by a real
Prometheus. From here:

- [How to scrape native histograms](../how-to/scrape-native-histograms.md) covers the two
  scrape-config options and how to confirm a scrape is picking one up.
- [Concurrency model](../explanation/concurrency.md) explains why sharing one registry
  across `--threaded --count N` is safe.
