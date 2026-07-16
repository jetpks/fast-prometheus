# AGENTS.md

Standing context for agents working in this repository.

## Commands

```bash
bundle install
bundle exec sus
bundle exec rubocop
bundle exec ruby script/e2e_prometheus_scrape.rb
```

## Style Rules

- 2-space indentation
- `# frozen_string_literal: true` on every source file
- Double-quoted strings (`"..."`)
- Fibers, never threads: no `Thread`, `Mutex`, or `Monitor` anywhere in the codebase

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
