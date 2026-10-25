# frozen_string_literal: true

# The completions-adapter suite (I02): the scenario matrix and allocation
# gates against a protocol-level fake — direct five-hook dispatch in the
# frozen order and shapes, args prebuilt — plus one end-to-end describe
# against a scripted OpenAI-compatible endpoint. fast-completions is a
# runtime peer wired as a path gem from gems.rb in a side-by-side checkout;
# in a lone checkout it is absent, the require fails, and this whole suite
# skips rather than failing without its protocol counterpart.
begin
  require "fast/completions"
rescue LoadError
  # fast-completions absent (lone checkout) — the adapter suite skips.
else
  require "fast/prometheus/instrumentation/completions"
  require "fast/prometheus/formats/text"
  require "json"
  require "async/http/server"
  require "sus/fixtures/async"

  describe Fast::Prometheus::Instrumentation::Completions do
    let(:registry) { Fast::Prometheus::Registry.new }

    def adapter(registry = self.registry)
      Fast::Prometheus::Instrumentation::Completions.new(registry: registry)
    end

    # The protocol fake's fixtures, prebuilt outside every measured window.
    def message(provider: "openai", model: "gpt-4o",
                usage: Fast::Completions::Usage.new(input: 10, output: 5),
                content: [{ type: :text, text: "Hello" }])
      Fast::Completions::Message.new(
        role: :assistant, content: content, provider: provider, model: model, usage: usage
      )
    end

    # Direct hook dispatch in the frozen order: start, at most one ttfb at
    # the first payload, then exactly one of end/error. Immediates only —
    # the strings come off the prebuilt message, the numbers are flonums.
    def dispatch_completion(sink, message, stop_reason: :stop, duration: 1.5, ttfb: 0.25)
      sink.on_completion_start(message.model, 123)
      sink.on_completion_ttfb(ttfb)
      sink.on_completion_end(stop_reason, duration, message)
    end

    describe "scenario matrix" do
      it "records all five metrics for a happy completion with usage" do
        labels = { provider: "openai", model: "gpt-4o" }
        dispatch_completion(adapter, message)

        total = registry.get(:llm_completions_total)
        tokens = registry.get(:llm_completions_tokens_total)
        expect(total.get(labels: labels.merge(stop_reason: "stop"))).to be(:==, 1.0)
        expect(registry.get(:llm_completions_duration_seconds).count(labels: labels)).to be(:==, 1)
        expect(registry.get(:llm_completions_duration_seconds).sum(labels: labels)).to be(:==, 1.5)
        expect(registry.get(:llm_completions_ttfb_seconds).count).to be(:==, 1)
        expect(registry.get(:llm_completions_ttfb_seconds).sum).to be(:==, 0.25)
        expect(tokens.get(labels: labels.merge(kind: "input"))).to be(:==, 10.0)
        expect(tokens.get(labels: labels.merge(kind: "output"))).to be(:==, 5.0)
        expect(registry.get(:llm_completions_errors_total).values).to be(:==, {})
      end

      it "counts a tool-call completion under its own stop_reason series" do
        tool_call = message(content: [{ type: :tool_call, id: "call-1", name: "lookup", arguments: {} }])
        adapter.on_completion_end(:tool_use, 2.0, tool_call)

        labels = { provider: "openai", model: "gpt-4o", stop_reason: "tool_use" }
        expect(registry.get(:llm_completions_total).get(labels: labels)).to be(:==, 1.0)
      end

      it "closes an errored completion on the errors counter only — no success series, no duration" do
        sink = adapter
        sink.on_completion_start("gpt-4o", 123)
        sink.on_completion_error(:rate_limit_error, 0.4)

        expect(registry.get(:llm_completions_errors_total).get(labels: { error: "rate_limit_error" })).to be(:==, 1.0)
        expect(registry.get(:llm_completions_total).values).to be(:==, {})
        expect(registry.get(:llm_completions_duration_seconds).values).to be(:==, {})
        expect(registry.get(:llm_completions_ttfb_seconds).count).to be(:==, 0)
        expect(registry.get(:llm_completions_tokens_total).values).to be(:==, {})
      end

      it "skips the token counters when usage is nil, recording everything else" do
        dispatch_completion(adapter, message(usage: nil))

        labels = { provider: "openai", model: "gpt-4o" }
        expect(registry.get(:llm_completions_total).get(labels: labels.merge(stop_reason: "stop"))).to be(:==, 1.0)
        expect(registry.get(:llm_completions_duration_seconds).count(labels: labels)).to be(:==, 1)
        expect(registry.get(:llm_completions_tokens_total).values).to be(:==, {})
      end

      it "collapses nil provider and model onto the unknown sentinel series" do
        dispatch_completion(adapter, message(provider: nil, model: nil))

        unknown = { provider: "unknown", model: "unknown" }
        expect(registry.get(:llm_completions_total).get(labels: unknown.merge(stop_reason: "stop"))).to be(:==, 1.0)
        expect(registry.get(:llm_completions_duration_seconds).count(labels: unknown)).to be(:==, 1)
        expect(registry.get(:llm_completions_tokens_total).get(labels: unknown.merge(kind: "input"))).to be(:==, 10.0)
      end

      it "reuses the registered metrics for a second adapter on the same registry" do
        one = adapter
        two = Fast::Prometheus::Instrumentation::Completions.new(registry: registry)
        expect(registry.metrics.size).to be(:==, 5)

        happy = message
        dispatch_completion(one, happy)
        dispatch_completion(two, happy)

        labels = { provider: "openai", model: "gpt-4o" }
        expect(registry.get(:llm_completions_total).get(labels: labels.merge(stop_reason: "stop"))).to be(:==, 2.0)
        expect(registry.get(:llm_completions_duration_seconds).count(labels: labels)).to be(:==, 2)
      end

      it "raises InvalidMetricType when a pre-registered metric has the wrong type" do
        registry.gauge(:llm_completions_total, docstring: "clash", labels: %i[provider model stop_reason])

        expect { adapter }.to raise_exception(Fast::Prometheus::InvalidMetricType)
      end

      it "raises InvalidLabelSet when a pre-registered metric declares other labels" do
        registry.counter(:llm_completions_errors_total, docstring: "clash", labels: %i[error code])

        expect { adapter }.to raise_exception(Fast::Prometheus::InvalidLabelSet)
      end

      it "renders all five metric names in the text exposition" do
        dispatch_completion(adapter, message)

        body = Fast::Prometheus::Formats::Text.render(registry.collect)
        %w[
          llm_completions_total
          llm_completions_errors_total
          llm_completions_duration_seconds
          llm_completions_ttfb_seconds
          llm_completions_tokens_total
        ].each do |name|
          expect(body).to be(:include?, name)
        end
      end
    end

    describe "allocation gates" do
      # Objects allocated per run of the block, averaged over +times+ runs
      # so a one-off allocation outside the block does not count (the house
      # shape, test/fast/prometheus/allocations.rb).
      def allocations(times = 1, &block)
        before = GC.stat(:total_allocated_objects)
        times.times(&block)
        (GC.stat(:total_allocated_objects) - before) / times.to_f
      end

      # Steady state is pinned at ZERO objects per completion: the hooks are
      # chained Hash lookups into pre-bound metrics on existing refs, and
      # kwargs (increment(by:)) are allocation-free. Pin provenance:
      # measured @ 7ed58c6 + prototype, ruby 4.0.7 arm64-darwin23, freeze
      # session.
      it "dispatches a warm happy completion with zero allocations" do
        sink = Fast::Prometheus::Instrumentation::Completions.new(registry: Fast::Prometheus::Registry.new)
        happy = message
        sink.on_completion_start(happy.model, 123)
        30.times { dispatch_completion(sink, happy) }
        allocations(100) { nil } # the first measured window eats harness noise

        expect(allocations(100) { dispatch_completion(sink, happy) }).to be(:<, 1)
      end

      it "dispatches a warm nil-usage completion with zero allocations" do
        sink = Fast::Prometheus::Instrumentation::Completions.new(registry: Fast::Prometheus::Registry.new)
        bare = message(usage: nil)
        sink.on_completion_start(bare.model, 123)
        30.times { dispatch_completion(sink, bare) }
        allocations(100) { nil }

        expect(allocations(100) { dispatch_completion(sink, bare) }).to be(:<, 1)
      end

      it "dispatches a warm error completion with zero allocations" do
        sink = Fast::Prometheus::Instrumentation::Completions.new(registry: Fast::Prometheus::Registry.new)
        sink.on_completion_start("gpt-4o", 123)
        30.times { sink.on_completion_error(:rate_limit_error, 0.4) }
        allocations(100) { nil }

        expect(allocations(100) { sink.on_completion_error(:rate_limit_error, 0.4) }).to be(:<, 1)
      end

      # PIN-1: measured 0 objects per-run over 15 runs at freeze.
      it "observes a warm ttfb with zero allocations" do
        sink = Fast::Prometheus::Instrumentation::Completions.new(registry: Fast::Prometheus::Registry.new)
        30.times { sink.on_completion_ttfb(0.25) }
        allocations(100) { nil }

        expect(allocations(15) { sink.on_completion_ttfb(0.25) }).to be(:<, 1)
      end

      # PIN-2: the no-op baseline is zero too, so the adapter's zero is the
      # protocol's own floor, not a budget both sides fit under.
      it "dispatches the same happy sequence to a bare no-op sink with zero allocations" do
        noop = Class.new { include Fast::Completions::Telemetry::Sink }.new
        happy = message
        30.times { dispatch_completion(noop, happy) }
        allocations(100) { nil }

        expect(allocations(100) { dispatch_completion(noop, happy) }).to be(:<, 1)
      end

      # The miss budget: a FIRST end dispatch for an unseen (provider,
      # model) binds four series (end, duration, two token kinds) once.
      # Measured 119–122 at freeze; budget 130. Provenance: measured @
      # 7ed58c6 + prototype, ruby 4.0.7 arm64-darwin23, freeze session.
      it "binds a first end dispatch for an unseen provider/model within budget" do
        sink = Fast::Prometheus::Instrumentation::Completions.new(registry: Fast::Prometheus::Registry.new)
        dispatch_completion(sink, message) # warm the code path on an unrelated series
        firsts = 5.times.map { |i| message(provider: "cold-#{i}", model: "cold-model-#{i}") }
        allocations(100) { nil }

        expect(allocations(5) { |i| sink.on_completion_end(:stop, 1.5, firsts[i]) }).to be(:<, 130)
      end

      # A FIRST error dispatch binds one series. Measured 19–22 at freeze;
      # budget 30. Same provenance as the end-miss pin above.
      it "binds a first error dispatch for an unseen error symbol within budget" do
        sink = Fast::Prometheus::Instrumentation::Completions.new(registry: Fast::Prometheus::Registry.new)
        sink.on_completion_error(:rate_limit_error, 0.4)
        cold = %i[a_cold_error b_cold_error c_cold_error d_cold_error e_cold_error]
        allocations(100) { nil }

        expect(allocations(5) { |i| sink.on_completion_error(cold[i], 0.4) }).to be(:<, 30)
      end
    end

    describe "end-to-end with a real client" do
      include Sus::Fixtures::Async::ReactorContext

      def sse_frame(payload)
        "data: #{JSON.generate(payload)}\n\n"
      end

      it "records the exact series for a streamed completion and a 429 exhaustion" do
        registry = Fast::Prometheus::Registry.new
        sink = Fast::Prometheus::Instrumentation::Completions.new(registry: registry)

        # Learn a free port, then serve the scripted endpoint on it.
        probe = TCPServer.new("127.0.0.1", 0)
        port = probe.addr[1]
        probe.close

        stream = [
          sse_frame("id" => "chatcmpl-1", "model" => "mock-model",
                    "choices" => [{ "delta" => { "role" => "assistant", "content" => "Hel" } }]),
          sse_frame("id" => "chatcmpl-1", "model" => "mock-model",
                    "choices" => [{ "delta" => { "content" => "lo" } }]),
          sse_frame("id" => "chatcmpl-1", "model" => "mock-model",
                    "choices" => [{ "delta" => {}, "finish_reason" => "stop" }]),
          sse_frame("usage" => { "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 }),
          "data: [DONE]\n\n"
        ]
        too_many_requests = JSON.generate("error" => { "message" => "slow down", "type" => "rate_limit_error" })

        # The scripted wire: one SSE completion, then 429 JSON twice — the
        # client's single creation retry exhausts on the second.
        script = %i[stream rate_limited rate_limited]
        endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}")
        handler = Async::HTTP::Server.for(endpoint) do |_request|
          if script.shift == :stream
            Protocol::HTTP::Response[200, { "content-type" => "text/event-stream" }, stream]
          else
            Protocol::HTTP::Response[429, { "content-type" => "application/json" }, [too_many_requests]]
          end
        end
        server_task = Async::HTTP::Server.new(handler, endpoint).run

        model = Fast::Completions::Model.new(
          id: "mock-model", reasoning: false, context_window: 128_000, max_tokens: 64,
          dialect: :fireworks, provider: "mock"
        )
        client = Fast::Completions::Client.new(
          base_url: "http://127.0.0.1:#{port}/v1", api_key: "test-key", telemetry: [sink]
        )
        prompt = [Fast::Completions::Message.user("hi")]

        streamed = nil
        errored = nil
        work = Async do |task|
          streamed = task.with_timeout(5) { client.stream(model: model, messages: prompt) }
          begin
            task.with_timeout(5) { client.stream(model: model, messages: prompt) }
          rescue Fast::Completions::RateLimitError
            errored = true
          end
        end
        work.wait
        client.close
        server_task.stop

        expect(streamed.content).to be(:==, [{ type: :text, text: "Hello" }])
        expect(streamed.usage.input).to be(:==, 10)
        expect(streamed.usage.output).to be(:==, 5)
        expect(errored).to be(:==, true)

        labels = { provider: "mock", model: "mock-model" }
        tokens = registry.get(:llm_completions_tokens_total)
        expect(registry.get(:llm_completions_total).get(labels: labels.merge(stop_reason: "stop"))).to be(:==, 1.0)
        expect(registry.get(:llm_completions_duration_seconds).count(labels: labels)).to be(:==, 1)
        expect(registry.get(:llm_completions_ttfb_seconds).count).to be(:==, 1)
        expect(tokens.get(labels: labels.merge(kind: "input"))).to be(:==, 10.0)
        expect(tokens.get(labels: labels.merge(kind: "output"))).to be(:==, 5.0)
        expect(registry.get(:llm_completions_errors_total).get(labels: { error: "rate_limit_error" })).to be(:==, 1.0)
      end
    end
  end
end
