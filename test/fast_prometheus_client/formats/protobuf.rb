# frozen_string_literal: true

require "fast_prometheus_client"
require "fast_prometheus_client/formats/protobuf"

describe FastPrometheusClient::Formats::Protobuf do
  def split_frames(bin)
    frames = []
    i = 0
    while i < bin.bytesize
      len = 0
      shift = 0
      loop do
        b = bin.getbyte(i)
        len |= (b & 0x7f) << shift
        shift += 7
        i += 1
        break if b < 0x80
      end
      frames << bin.byteslice(i, len)
      i += len
    end
    frames
  end

  describe ".render" do
    it "round-trips all five metric types" do
      r = FastPrometheusClient::Registry.new
      r.counter(:requests_total, docstring: "total requests").increment
      r.gauge(:temperature_celsius, docstring: "temperature").set(23.5)
      r.summary(:request_duration_seconds, docstring: "request duration").observe(1.5)
      r.histogram(:response_time_seconds, docstring: "response time").observe(0.5)
      nh = r.native_histogram(:lat_seconds, docstring: "latency")
      [0.5, 1.5, 1.5, 4.0].each { |v| nh.observe(v) }

      bin = FastPrometheusClient::Formats::Protobuf.render(r.collect)
      frames = split_frames(bin)

      expect(frames.size).to be(:==, 5)

      mf = Io::Prometheus::Client::MetricFamily.decode(frames[0])
      expect(mf.name).to be(:==, "requests_total")
      expect(mf.type).to be(:==, :COUNTER)
      expect(mf.metric.first.counter.value).to be(:==, 1.0)

      mf = Io::Prometheus::Client::MetricFamily.decode(frames[1])
      expect(mf.name).to be(:==, "temperature_celsius")
      expect(mf.type).to be(:==, :GAUGE)
      expect(mf.metric.first.gauge.value).to be(:==, 23.5)

      mf = Io::Prometheus::Client::MetricFamily.decode(frames[2])
      expect(mf.name).to be(:==, "request_duration_seconds")
      expect(mf.type).to be(:==, :SUMMARY)
      s = mf.metric.first.summary
      expect(s.sample_count).to be(:==, 1)
      expect(s.sample_sum).to be(:==, 1.5)

      mf = Io::Prometheus::Client::MetricFamily.decode(frames[3])
      expect(mf.name).to be(:==, "response_time_seconds")
      expect(mf.type).to be(:==, :HISTOGRAM)
      h = mf.metric.first.histogram
      expect(h.sample_count).to be(:==, 1)
      expect(h.sample_sum).to be(:==, 0.5)
      expect(h.bucket.last.upper_bound).to be(:==, Float::INFINITY)

      mf = Io::Prometheus::Client::MetricFamily.decode(frames[4])
      expect(mf.name).to be(:==, "lat_seconds")
      h = mf.metric.first.histogram
      expect(h.sample_count).to be(:==, 4)
      expect(h.schema).to be(:==, 3)
      expect(h.positive_span.length).to be(:>, 0)
    end

    it "round-trips labeled counter and labeled native histogram" do
      r = FastPrometheusClient::Registry.new
      counter = r.counter(:http_requests_total, docstring: "http requests", labels: %i[method status])
      counter.increment(by: 42, labels: { method: "GET", status: "200" })
      counter.increment(by: 7, labels: { method: "POST", status: "500" })

      nh = r.native_histogram(:http_duration_seconds, docstring: "http duration", labels: %i[method])
      nh.observe(0.1, labels: { method: "GET" })
      nh.observe(0.5, labels: { method: "GET" })
      nh.observe(2.0, labels: { method: "POST" })

      bin = FastPrometheusClient::Formats::Protobuf.render(r.collect)
      frames = split_frames(bin)
      expect(frames.size).to be(:==, 2)

      # Verify labeled counter
      mf = Io::Prometheus::Client::MetricFamily.decode(frames[0])
      expect(mf.name).to be(:==, "http_requests_total")
      expect(mf.metric.size).to be(:==, 2)

      mf.metric.each do |metric|
        labels = metric.label.to_a
        method_label = labels.find { |lp| lp.name == "method" }
        status_label = labels.find { |lp| lp.name == "status" }

        if method_label.value == "GET"
          expect(status_label.value).to be(:==, "200")
          expect(metric.counter.value).to be(:==, 42.0)
        elsif method_label.value == "POST"
          expect(status_label.value).to be(:==, "500")
          expect(metric.counter.value).to be(:==, 7.0)
        end
      end

      # Verify labeled native histogram
      mf = Io::Prometheus::Client::MetricFamily.decode(frames[1])
      expect(mf.name).to be(:==, "http_duration_seconds")
      expect(mf.metric.size).to be(:==, 2)

      mf.metric.each do |metric|
        labels = metric.label.to_a
        method_label = labels.find { |lp| lp.name == "method" }

        if method_label.value == "GET"
          expect(metric.histogram.sample_count).to be(:==, 2)
        elsif method_label.value == "POST"
          expect(metric.histogram.sample_count).to be(:==, 1)
        end
      end
    end
  end

  describe ".build_spans_deltas" do
    it "worked example: [[1, 3], [2, 1], [5, 4]]" do
      spans, deltas = FastPrometheusClient::Formats::Protobuf.build_spans_deltas([[1, 3], [2, 1], [5, 4]])
      expect(spans.map { |s| [s.offset, s.length] }).to be(:==, [[1, 2], [2, 1]])
      expect(deltas).to be(:==, [3, -2, 3])
    end

    it "handles empty buckets" do
      spans, deltas = FastPrometheusClient::Formats::Protobuf.build_spans_deltas([])
      expect(spans).to be(:==, [])
      expect(deltas).to be(:==, [])
    end

    it "handles single bucket" do
      spans, deltas = FastPrometheusClient::Formats::Protobuf.build_spans_deltas([[0, 5]])
      expect(spans.map { |s| [s.offset, s.length] }).to be(:==, [[0, 1]])
      expect(deltas).to be(:==, [5])
    end
  end
end
