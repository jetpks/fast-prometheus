# Reference: require paths and dependencies

`require "fast/prometheus"` loads only the core (metrics, registry, snapshot) — zero IO dependencies. Every other surface is opt-in, requires the core itself, and is independently requirable:

| Require path | Pulls in |
|---|---|
| `fast/prometheus` | core only — no IO deps |
| `fast/prometheus/formats/text` | core |
| `fast/prometheus/formats/protobuf` | core, fast-protowire |
| `fast/prometheus/middleware/exporter` | core, protocol-http, both formats |
| `fast/prometheus/middleware/instrumentation` | core, protocol-http |
| `fast/prometheus/rack/exporter` | core, both formats, zlib |
| `fast/prometheus/rack/instrumentation` | core |
| `fast/prometheus/otlp/mapper` | core, fast-protowire |
| `fast/prometheus/otlp/http_exporter` | core, async-http |
| `fast/prometheus/otlp/grpc_exporter` | core, async-http, async-grpc |
| `fast/prometheus/otlp/push` | core, async, console |
| `fast/prometheus/otlp/service_interface` | core, protocol-grpc |

Neither exposition nor OTLP export loads `google-protobuf`. The Prometheus client model and the OTLP messages are declared with [fast-protowire](https://github.com/jetpks/fast-protowire) under `Fast::Prometheus::Formats::Protobuf::Proto` and `Fast::Prometheus::OTLP::Proto`, so nothing registers protobuf descriptors and there is no conflict with the `opentelemetry-proto` gem or any other descriptor pool in the process.
