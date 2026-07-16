# frozen_string_literal: true

require "fast_prometheus_client"

describe FastPrometheusClient::OTLP::Mapper do
  let(:registry) { FastPrometheusClient::Registry.new }
  let(:start_time) { Time.now }
  let(:mapper) { FastPrometheusClient::OTLP::Mapper.new(start_time: start_time) }

  describe "#request" do
    describe "counter" do
      before { registry.counter(:jobs_total, docstring: "Jobs").increment(by: 3) }
      let(:snapshot) { registry.collect }

      it "produces a Sum with is_monotonic true and CUMULATIVE temporality" do
        req = mapper.request(snapshot)
        metric = req.resource_metrics.first.scope_metrics.first.metrics.first
        expect(metric.name).to be(:==, "jobs_total")
        expect(metric.description).to be(:==, "Jobs")
        expect(metric.sum.is_monotonic).to be(:==, true)
        expect(metric.sum.aggregation_temporality).to be(:==, :AGGREGATION_TEMPORALITY_CUMULATIVE)
      end

      it "has correct NumberDataPoint" do
        req = mapper.request(snapshot)
        dp = req.resource_metrics.first.scope_metrics.first.metrics.first.sum.data_points.first
        expect(dp.as_double).to be(:==, 3.0)
        expect(dp.start_time_unix_nano).to be(:==, (start_time.to_f * 1_000_000_000).to_i)
      end
    end

    describe "gauge" do
      before { registry.gauge(:temp, docstring: "Temperature").set(21.5) }
      let(:snapshot) { registry.collect }

      it "produces a Gauge with correct NumberDataPoint" do
        req = mapper.request(snapshot)
        metric = req.resource_metrics.first.scope_metrics.first.metrics.first
        expect(metric.name).to be(:==, "temp")
        expect(metric.gauge.data_points.first.as_double).to be(:==, 21.5)
      end
    end

    describe "histogram" do
      before do
        h = registry.histogram(:dur, docstring: "Duration", buckets: [0.5, 1.0, 2.0])
        h.observe(0.3)
        h.observe(0.7)
        h.observe(1.5)
      end
      let(:snapshot) { registry.collect }

      it "produces a Histogram with CUMULATIVE temporality" do
        req = mapper.request(snapshot)
        metric = req.resource_metrics.first.scope_metrics.first.metrics.first
        expect(metric.histogram.aggregation_temporality).to be(:==, :AGGREGATION_TEMPORALITY_CUMULATIVE)
      end

      it "has non-cumulative bucket_counts with overflow" do
        req = mapper.request(snapshot)
        dp = req.resource_metrics.first.scope_metrics.first.metrics.first.histogram.data_points.first
        # boundaries: [0.5, 1.0, 2.0] — no +Inf
        expect(dp.explicit_bounds.to_a).to be(:==, [0.5, 1.0, 2.0])
        # cumulative: [0.5,1] [1.0,2] [2.0,3] [+Inf,3]
        # non-cumulative: 1, 1, 1, 0 (overflow)
        expect(dp.bucket_counts.to_a).to be(:==, [1, 1, 1, 0])
        expect(dp.count).to be(:==, 3)
      end
    end

    describe "summary" do
      before do
        s = registry.summary(:size, docstring: "Size")
        s.observe(100)
        s.observe(200)
      end
      let(:snapshot) { registry.collect }

      it "produces a Summary with sum and count, no quantiles" do
        req = mapper.request(snapshot)
        dp = req.resource_metrics.first.scope_metrics.first.metrics.first.summary.data_points.first
        expect(dp.count).to be(:==, 2)
        expect(dp.sum).to be(:==, 300.0)
        expect(dp.quantile_values).to be(:==, [])
      end
    end

    describe "native_histogram" do
      before { registry.native_histogram(:lat_seconds, docstring: "Latency").observe(1.5) }
      let(:snapshot) { registry.collect }

      it "produces an ExponentialHistogram with CUMULATIVE temporality" do
        req = mapper.request(snapshot)
        metric = req.resource_metrics.first.scope_metrics.first.metrics.first
        expect(metric.exponential_histogram.aggregation_temporality).to be(:==, :AGGREGATION_TEMPORALITY_CUMULATIVE)
      end

      it "maps prom index to otlp index with offset = prom_min - 1" do
        # observe(1.5) at schema 3 → prom idx 5 → otlp offset 4, counts [1]
        req = mapper.request(snapshot)
        dp = req.resource_metrics.first.scope_metrics.first.metrics.first.exponential_histogram.data_points.first
        expect(dp.scale).to be(:==, 3)
        expect(dp.positive.offset).to be(:==, 4)
        expect(dp.positive.bucket_counts.to_a).to be(:==, [1])
      end

      it "fills gaps with zeros for sparse observations" do
        registry2 = FastPrometheusClient::Registry.new
        nh = registry2.native_histogram(:lat, docstring: "L")
        nh.observe(1.5)  # schema 3 → prom idx 5 → otlp idx 4
        nh.observe(64.0) # schema 3 → prom idx 48 → otlp idx 47
        snap = registry2.collect
        mapper2 = FastPrometheusClient::OTLP::Mapper.new
        req = mapper2.request(snap)
        dp = req.resource_metrics.first.scope_metrics.first.metrics.first.exponential_histogram.data_points.first
        expect(dp.positive.offset).to be(:==, 4)
        counts = dp.positive.bucket_counts.to_a
        expect(counts.length).to be(:==, 44) # 47 - 4 + 1
        expect(counts[0]).to be(:==, 1) # otlp idx 4
        expect(counts[43]).to be(:==, 1) # otlp idx 47
        expect(counts[1..42].all?(&:zero?)).to be(:==, true)
      end
    end

    describe "resource and scope" do
      before { registry.counter(:x, docstring: "X").increment }
      let(:snapshot) { registry.collect }

      it "has correct scope name and version" do
        req = mapper.request(snapshot)
        scope = req.resource_metrics.first.scope_metrics.first.scope
        expect(scope.name).to be(:==, "fast-prometheus-client")
        expect(scope.version).to be(:==, FastPrometheusClient::VERSION)
      end

      it "maps resource_attributes to KeyValue" do
        mapper_with_attrs = FastPrometheusClient::OTLP::Mapper.new(
          resource_attributes: { "service.name" => "my-app" },
          start_time: start_time
        )
        req = mapper_with_attrs.request(snapshot)
        attr = req.resource_metrics.first.resource.attributes.first
        expect(attr.key).to be(:==, "service.name")
        expect(attr.value.string_value).to be(:==, "my-app")
      end
    end

    describe "start_time stability" do
      before { registry.counter(:c, docstring: "C").increment }

      it "uses the same start_time across two requests" do
        snap1 = registry.collect
        req1 = mapper.request(snap1)
        dp1 = req1.resource_metrics.first.scope_metrics.first.metrics.first.sum.data_points.first
        start1 = dp1.start_time_unix_nano

        snap2 = registry.collect
        req2 = mapper.request(snap2)
        dp2 = req2.resource_metrics.first.scope_metrics.first.metrics.first.sum.data_points.first
        start2 = dp2.start_time_unix_nano

        expect(start1).to be(:==, start2)
      end
    end
  end
end
