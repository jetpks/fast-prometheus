# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :test do
  gem "sus"
  gem "sus-fixtures-async"
  gem "sus-fixtures-async-http"
  gem "covered"
  gem "rubocop"
  gem "rack", "~> 3.1"
  # Reference decoder for the exposition and OTLP tests (fixtures/pb); never a runtime dependency.
  gem "google-protobuf", "~> 4.36"

  # The completions-adapter tests consume the fast-completions telemetry
  # protocol — a runtime peer, never a dependency of this gemspec. In a
  # side-by-side checkout (this space) the sibling repo is wired as a path
  # gem, found by walking up from this file so it resolves from the repo
  # checkout and from a lane worktree alike; a lone checkout resolves
  # without it and the adapter suite skips with it.
  completions = nil
  base = __dir__
  loop do
    candidate = File.join(base, "repos", "fast-llm", "gems", "completions")
    if File.directory?(candidate)
      completions = candidate
      break
    end

    break if base == (parent = File.dirname(base))

    base = parent
  end
  gem "fast-completions", path: completions if completions
end

group :benchmark do
  gem "benchmark-ips"
  gem "prometheus-client"
end
