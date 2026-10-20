# How to instrument LLM completions

Record metrics for every completion a [fast-completions](https://github.com/jetpks/fast-llm)
client streams — counters for completions, errors and tokens, histograms for duration and
time-to-first-byte — with `Fast::Prometheus::Instrumentation::Completions`, the telemetry sink
for `Fast::Completions::Client`. You need an app that already constructs a
`Fast::Completions::Client` and a `Registry` you can scrape.

## Steps

1. Add the peer gem to your `Gemfile` and require the adapter:

   ```ruby
   gem "fast-completions"
   ```

   ```ruby
   require "fast/prometheus/instrumentation/completions"
   ```

   `fast-completions` is a runtime peer, never a dependency of the fast-prometheus gemspec: the
   require path issues a soft require of `fast/completions/telemetry` and fails loud with
   `LoadError` when the peer gem is absent, instead of half-loading a sink that can never fire.

2. Construct the sink — with a registry keyword when you don't want the default — and hand it to
   the client in its `telemetry:` array:

   ```ruby
   sink = Fast::Prometheus::Instrumentation::Completions.new(registry: Fast::Prometheus.registry)

   client = Fast::Completions::Client.new(
     base_url: "https://api.example.com/v1",
     api_key: "...",
     telemetry: [sink]
   )
   ```

   Construction registers the five metrics below through `Registry#fetch_or_register`, so a
   second sink on the same registry reuses them and shares their series. A metric someone
   pre-registered under one of these names must be the table's type and declare the table's
   labels, or construction raises `InvalidMetricType` / `InvalidLabelSet` once, at boot — the
   `RequestMetrics` pattern.

   | Metric | Type | Labels |
   |---|---|---|
   | `llm_completions_total` | counter | `provider`, `model`, `stop_reason` |
   | `llm_completions_errors_total` | counter | `error` |
   | `llm_completions_duration_seconds` | histogram (default buckets) | `provider`, `model` |
   | `llm_completions_ttfb_seconds` | histogram (default buckets) | — |
   | `llm_completions_tokens_total` | counter | `provider`, `model`, `kind` |

   Label values: `provider` and `model` come from the completion's assistant Message (`nil`
   collapses to `"unknown"` — the wire's `response_model`/`response_id` are never labels, they
   drift on server version and vanish on same-model streams), `stop_reason` and `error` are the
   telemetry hook Symbols, and `kind` is the frozen `"input"`/`"output"` pair from the
   completion's token usage — a completion without usage skips the token counters entirely.

3. Stream as usual. Nothing changes at the call sites; the sink is notified around every
   `Client#stream` invocation:

   ```ruby
   message = client.stream(model: model, messages: messages)
   ```

4. Verify: scrape the registry (see [how to instrument a Rack app](instrument-a-rack-app.md)
   for serving `/metrics`) and check the rendered names:

   ```console
   $ curl localhost:PORT/metrics | grep ^llm_completions
   # HELP llm_completions_total Total LLM completions by stop reason
   # TYPE llm_completions_total counter
   ...
   llm_completions_total{provider="fast-completions",model="my-model",stop_reason="stop"} 1
   llm_completions_duration_seconds_count{provider="fast-completions",model="my-model"} 1
   llm_completions_ttfb_seconds_count 1
   llm_completions_tokens_total{provider="fast-completions",model="my-model",kind="input"} 10
   llm_completions_tokens_total{provider="fast-completions",model="my-model",kind="output"} 5
   ```

## Result

Every completion leaves its mark: returned completions add one to `llm_completions_total` under
their stop reason, one duration observation, one TTFB observation, and their token usage under
`kind="input"`/`kind="output"`; a completion that raises out of `Client#stream` adds one to
`llm_completions_errors_total` under the error's Symbol and nothing else — errored completions
get no duration.

Two operational notes. Cardinality: nothing reclaims a series once it exists, and the label
values are operator-controlled — `provider` and `model` are whatever the `Fast::Completions`
`Model` you stream with declares, so the five families grow with the models you configure, not
with your traffic. Concurrency: construct one sink per client and hand it to that client's
`telemetry:` array — the client notifies its sinks inside the streaming task's own single-flight
discipline, and the registry beneath is safe to share across threads and fibers (see
[Concurrency model](../explanation/concurrency.md)).
