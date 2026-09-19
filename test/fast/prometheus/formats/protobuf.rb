# frozen_string_literal: true

require "fast/prometheus"
require "reference"
require "fast/prometheus/formats/protobuf"

describe Fast::Prometheus::Formats::Protobuf do
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
    it "encodes a labeled multi-series family byte-identically to one MetricFamily message" do
      r = Fast::Prometheus::Registry.new
      c = r.counter(:jobs_total, docstring: "jobs", labels: %i[queue state])
      c.increment(by: 2, labels: { queue: "mail", state: "done" })
      c.increment(labels: { queue: "mail", state: "failed" })
      c.increment(by: 7, labels: { queue: "sms", state: "done" })

      frame = split_frames(Fast::Prometheus::Formats::Protobuf.render(r.collect)).first
      reference = Io::Prometheus::Client::MetricFamily.new(
        name: "jobs_total", help: "jobs", type: :COUNTER,
        metric: [%w[mail done 2], %w[mail failed 1], %w[sms done 7]].map do |queue, state, value|
          Io::Prometheus::Client::Metric.new(
            label: [Io::Prometheus::Client::LabelPair.new(name: "queue", value: queue),
                    Io::Prometheus::Client::LabelPair.new(name: "state", value: state)],
            counter: Io::Prometheus::Client::Counter.new(value: value.to_f)
          )
        end
      )

      expect(frame).to be(:==, Io::Prometheus::Client::MetricFamily.encode(reference))
    end

    it "omits an empty label value, like the reference" do
      r = Fast::Prometheus::Registry.new
      c = r.counter(:jobs_total, docstring: "jobs", labels: %i[queue state])
      c.increment(labels: { queue: "", state: "done" })
      c.increment(by: 2, labels: { queue: "mail", state: "" })
      c.increment(by: 3, labels: { queue: "", state: "" })

      frame = split_frames(Fast::Prometheus::Formats::Protobuf.render(r.collect)).first
      reference = Io::Prometheus::Client::MetricFamily.new(
        name: "jobs_total", help: "jobs", type: :COUNTER,
        metric: [["", "done", 1], ["mail", "", 2], ["", "", 3]].map do |queue, state, value|
          Io::Prometheus::Client::Metric.new(
            label: [Io::Prometheus::Client::LabelPair.new(name: "queue", value: queue),
                    Io::Prometheus::Client::LabelPair.new(name: "state", value: state)],
            counter: Io::Prometheus::Client::Counter.new(value: value.to_f)
          )
        end
      )

      expect(frame).to be(:==, Io::Prometheus::Client::MetricFamily.encode(reference))
      expect(Io::Prometheus::Client::MetricFamily.decode(frame).metric.size).to be(:==, 3)
    end

    it "omits proto3 zero values and sends -0.0, like the reference" do
      r = Fast::Prometheus::Registry.new
      c = r.counter(:zero_total, docstring: "zero", labels: [:kind])
      c.init_label_set(kind: "unseen")
      r.gauge(:signed_zero, docstring: "signed").set(-0.0)
      r.summary(:empty_summary, docstring: "empty")
      h = r.histogram(:from_zero, docstring: "from zero", buckets: [0.0, 1.0])
      h.observe(0.0)

      frames = split_frames(Fast::Prometheus::Formats::Protobuf.render(r.collect))
      c = Io::Prometheus::Client
      references = [
        c::MetricFamily.new(name: "zero_total", help: "zero", type: :COUNTER,
                            metric: [c::Metric.new(label: [c::LabelPair.new(name: "kind", value: "unseen")],
                                                   counter: c::Counter.new)]),
        c::MetricFamily.new(name: "signed_zero", help: "signed", type: :GAUGE,
                            metric: [c::Metric.new(gauge: c::Gauge.new(value: -0.0))]),
        c::MetricFamily.new(name: "empty_summary", help: "empty", type: :SUMMARY,
                            metric: [c::Metric.new(summary: c::Summary.new)]),
        c::MetricFamily.new(name: "from_zero", help: "from zero", type: :HISTOGRAM,
                            metric: [c::Metric.new(histogram: c::Histogram.new(
                              sample_count: 1, sample_sum: 0.0,
                              bucket: [c::Bucket.new(cumulative_count: 1, upper_bound: 0.0),
                                       c::Bucket.new(cumulative_count: 1, upper_bound: 1.0),
                                       c::Bucket.new(cumulative_count: 1, upper_bound: Float::INFINITY)]
                            ))])
      ]

      expect(frames).to be(:==, references.map { |mf| c::MetricFamily.encode(mf) })
    end

    it "round-trips all five metric types" do
      r = Fast::Prometheus::Registry.new
      r.counter(:requests_total, docstring: "total requests").increment
      r.gauge(:temperature_celsius, docstring: "temperature").set(23.5)
      r.summary(:request_duration_seconds, docstring: "request duration").observe(1.5)
      r.histogram(:response_time_seconds, docstring: "response time").observe(0.5)
      nh = r.native_histogram(:lat_seconds, docstring: "latency")
      [0.5, 1.5, 1.5, 4.0].each { |v| nh.observe(v) }

      bin = Fast::Prometheus::Formats::Protobuf.render(r.collect)
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
      r = Fast::Prometheus::Registry.new
      counter = r.counter(:http_requests_total, docstring: "http requests", labels: %i[method status])
      counter.increment(by: 42, labels: { method: "GET", status: "200" })
      counter.increment(by: 7, labels: { method: "POST", status: "500" })

      nh = r.native_histogram(:http_duration_seconds, docstring: "http duration", labels: %i[method])
      nh.observe(0.1, labels: { method: "GET" })
      nh.observe(0.5, labels: { method: "GET" })
      nh.observe(2.0, labels: { method: "POST" })

      bin = Fast::Prometheus::Formats::Protobuf.render(r.collect)
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

  describe "native histogram spans and deltas" do
    def render_native(positive_buckets)
      value = Fast::Prometheus::NativeHistogramValue.new(
        schema: 3, zero_threshold: 2.0**-128, zero_count: 0, sum: 0.0,
        count: positive_buckets.sum { |_, count| count },
        positive_buckets: positive_buckets, negative_buckets: []
      )
      metric = Fast::Prometheus::MetricSnapshot.new(
        name: :h, docstring: "h", type: :native_histogram, label_names: [],
        series: { [] => value }
      )
      snapshot = Fast::Prometheus::Snapshot.new(metrics: [metric], taken_at: Time.now)
      frames = split_frames(Fast::Prometheus::Formats::Protobuf.render(snapshot))
      Io::Prometheus::Client::MetricFamily.decode(frames[0]).metric[0].histogram
    end

    it "encodes ascending sparse buckets as spans and deltas" do
      histogram = render_native([[1, 3], [2, 1], [5, 4]])
      expect(histogram.positive_span.map { |s| [s.offset, s.length] }).to be(:==, [[1, 2], [2, 1]])
      expect(histogram.positive_delta.to_a).to be(:==, [3, -2, 3])
    end

    it "encodes no buckets as no spans" do
      histogram = render_native([])
      expect(histogram.positive_span.to_a).to be(:==, [])
      expect(histogram.positive_delta.to_a).to be(:==, [])
    end

    it "encodes a single bucket as one span" do
      histogram = render_native([[0, 5]])
      expect(histogram.positive_span.map { |s| [s.offset, s.length] }).to be(:==, [[0, 1]])
      expect(histogram.positive_delta.to_a).to be(:==, [5])
    end
  end
end
