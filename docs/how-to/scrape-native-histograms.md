# How to scrape native histograms

Configure Prometheus to negotiate protobuf so a scrape picks up native histograms
(`NativeHistogram`, or `Middleware::Instrumentation.new(app, native: true)`), which the text
exposition format omits. You need a running Prometheus and an app exposing
`fast-prometheus` metrics over the `Middleware::Exporter` endpoint.

## Steps

1. Set `scrape_native_histograms: true` on the job's `scrape_config`:

   ```yaml
   scrape_configs:
     - job_name: "my_app"
       scrape_native_histograms: true
       static_configs:
         - targets: ["localhost:9394"]
   ```

   This tells Prometheus to recognize and ingest the native parts of a histogram during
   that job's scrapes; without it, native parts are ignored and only classic parts (if any)
   are kept.

2. Alternatively, list `PrometheusProto` first in `scrape_protocols` — the protocols
   Prometheus is willing to negotiate with the target, in preference order:

   ```yaml
   scrape_configs:
     - job_name: "my_app"
       scrape_protocols: ["PrometheusProto", "OpenMetricsText1.0.0"]
       static_configs:
         - targets: ["localhost:9394"]
   ```

   Setting `scrape_native_histograms: true` already prepends `PrometheusProto` to the
   default protocol list, so use `scrape_protocols` directly only when you need a custom
   order or a restricted list.

3. Reload or restart Prometheus with the config.

4. Confirm the config is valid:

   ```bash
   promtool check config prometheus.yml
   ```

5. Confirm the histogram scraped as native by querying its count:

   ```bash
   promtool query instant http://localhost:9090 'histogram_count(request_duration_seconds)'
   ```

   `histogram_count` only resolves against a native histogram series; it returns nothing for
   a classic histogram scraped without step 1 or 2.

## Result

Prometheus stores the native histogram alongside its classic metrics, and
`histogram_count(...)`/`histogram_quantile(...)` and other native-histogram PromQL functions
work against it.

See [Reference: exposition formats and HTTP middleware](../reference/exposition.md) for
`Formats::Protobuf` and `Middleware::Exporter`'s content negotiation, and
[Native histograms](../explanation/native-histograms.md) for why the text format can't carry
them.
