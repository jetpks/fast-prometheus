# fast-prometheus-client

A fiber-native Prometheus client for modern Ruby. Built on the socketry/async
ecosystem: zero-lock hot path under cooperative scheduling, native histograms
as a first-class metric type, protobuf scrape exposition, and OTLP export over
gRPC (async-grpc) and HTTP.

Not a fork of prometheus/client_ruby — a new gem that uses it as the reference
for supported surface.

> ⚠️ Under construction. Not yet released.

## Installation

```bash
gem install fast-prometheus-client
```

Or add to your `Gemfile`:

```ruby
gem "fast-prometheus-client"
```
