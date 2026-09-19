# AGENTS.md

Standing context for agents working in this repository.

## Commands

```bash
bundle install
bundle exec sus
bundle exec rubocop
bundle exec ruby script/e2e_prometheus_scrape.rb
BENCH_QUICK=1 bundle exec ruby benchmark/observe.rb
protoc --proto_path=proto --ruby_out=fixtures/pb proto/metrics.proto proto/opentelemetry/proto/**/*.proto   # regenerate the reference decoders (tests only)
bundle exec ruby script/scrape_rss.rb --mode server --series 7500   # RSS per scrape, see header
```

## Dependencies

- `google-protobuf` is a development dependency only: tests decode the library's output with it (`fixtures/reference.rb`). Runtime protobuf is `fast-protowire`; the message declarations live in `lib/fast/prometheus/formats/metrics_proto.rb` and `lib/fast/prometheus/otlp/proto.rb` and must mirror `proto/`.

## Style Rules

- 2-space indentation
- `# frozen_string_literal: true` on every source file
- Double-quoted strings (`"..."`)
- Fibers remain the IO concurrency model. `Thread::Mutex`/`Monitor` are permitted only where shared mutable state is guarded — metric stores and the registry. `Thread` is permitted only in tests and scripts that verify cross-thread behavior.

## Test Rules

- Use `sus` as the test framework
- Tests are terse, exercising public interfaces only
- No mock/stub of the class under test

## Local Reference Sources

- `~/architect/src/github.com/socketry/async`
- `~/architect/src/github.com/socketry/async-http`
- `~/architect/src/github.com/socketry/async-grpc`
- `~/architect/src/github.com/socketry/protocol-grpc`
- `~/architect/src/github.com/socketry/protocol-http`
- `~/architect/src/github.com/socketry/sus`
- `~/architect/src/github.com/socketry/sus-fixtures-async`
- `/Users/eric/architect/spaces/20260715-fast-prometheus-client/repos/client_ruby`
- `/Users/eric/architect/spaces/20260715-fast-prometheus-client/repos/prometheus`
