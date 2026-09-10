# Reference: require paths and dependencies

`require "fast/prometheus"` loads only the core (metrics, registry, snapshot) — zero IO dependencies. Every other surface is opt-in, requires the core itself, and is independently requirable:

| Require path | Pulls in |
|---|---|
| `fast/prometheus` | core only — no IO deps |
| `fast/prometheus/formats/text` | core |
| `fast/prometheus/formats/protobuf` | core, google-protobuf |
| `fast/prometheus/middleware/exporter` | core, protocol-http, both formats |
| `fast/prometheus/middleware/instrumentation` | core, protocol-http |
| `fast/prometheus/otlp/mapper` | core, vendored OTLP protos |
| `fast/prometheus/otlp/http_exporter` | core, async-http |
| `fast/prometheus/otlp/grpc_exporter` | core, async-http, async-grpc |
| `fast/prometheus/otlp/push` | core, async, console |
| `fast/prometheus/otlp/service_interface` | core, protocol-grpc |

The vendored `Opentelemetry::Proto` descriptors under `fast/prometheus/otlp/pb` may conflict with the `opentelemetry-proto` gem if both are loaded in the same process (duplicate protobuf descriptor registration). This only affects processes that opt into OTLP export (`fast/prometheus/otlp/mapper` and anything that requires it).
