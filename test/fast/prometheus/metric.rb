# frozen_string_literal: true

require "fast/prometheus"
require "sus/fixtures/async"

class TestMetric < Fast::Prometheus::Metric
  def type
    :test
  end

  def touch(labels: {})
    key = resolve(labels)
    store.synchronize { store[key] = (store[key] || 0.0) + 1.0 }
  end

  def public_resolve(labels)
    resolve(labels)
  end
end

describe Fast::Prometheus::Metric do
  describe ".new" do
    it "rejects invalid metric name" do
      expect { TestMetric.new("123bad".to_sym, docstring: "help") }.to raise_exception(Fast::Prometheus::InvalidMetricName)
    end

    it "accepts valid metric name" do
      expect { TestMetric.new(:valid_name, docstring: "help") }.not.to raise_exception
    end

    it "stores a String name as a Symbol" do
      metric = TestMetric.new("valid_name", docstring: "help")
      expect(metric.name).to be(:==, :valid_name)
    end

    it "seeds a zero-valued series when fully bound" do
      metric = TestMetric.new(:valid_name, docstring: "help")
      expect(metric.values).to be(:==, {} => 0.0)
    end

    it "seeds nothing when partially bound" do
      metric = TestMetric.new(:valid_name, docstring: "help", labels: [:method])
      expect(metric.values).to be(:==, {})
    end

    it "rejects nil docstring" do
      expect { TestMetric.new(:valid_name, docstring: nil) }.to raise_exception(ArgumentError)
    end

    it "rejects empty docstring" do
      expect { TestMetric.new(:valid_name, docstring: "") }.to raise_exception(ArgumentError)
    end

    it "rejects bad label name" do
      expect { TestMetric.new(:valid_name, docstring: "help", labels: ["123bad".to_sym]) }.to raise_exception(Fast::Prometheus::InvalidLabelName)
    end

    it "rejects __-prefixed label name" do
      expect { TestMetric.new(:valid_name, docstring: "help", labels: [:__reserved]) }.to raise_exception(Fast::Prometheus::InvalidLabelName)
    end

    it "rejects preset key not in labels" do
      expect do
        TestMetric.new(:valid_name, docstring: "help", labels: [:method], preset_labels: { unknown: "x" })
      end.to raise_exception(Fast::Prometheus::InvalidLabelSet)
    end

    it "transcodes a docstring in another encoding" do
      metric = TestMetric.new(:valid_name, docstring: "caf\xe9".dup.force_encoding("ISO-8859-1"))
      expect(metric.docstring).to be(:==, "café")
    end

    it "scrubs an invalid UTF-8 docstring" do
      metric = TestMetric.new(:valid_name, docstring: "caf\xff".b)
      expect(metric.docstring.encoding).to be(:==, Encoding::UTF_8)
      expect(metric.docstring.valid_encoding?).to be(:==, true)
    end
  end

  describe "label names" do
    it "normalizes String names to Symbols" do
      metric = TestMetric.new(:test, docstring: "help", labels: ["method"])
      expect(metric.labels).to be(:==, [:method])
    end

    it "accepts a Symbol key for a String-declared label" do
      metric = TestMetric.new(:test, docstring: "help", labels: ["method"])
      metric.touch(labels: { method: "get" })
      expect(metric.values).to be(:==, { method: "get" } => 1.0)
    end

    it "normalizes preset keys too" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method], preset_labels: { "method" => "get" })
      expect(metric.values).to be(:==, { method: "get" } => 0.0)
    end

    it "rejects duplicate names" do
      expect do
        TestMetric.new(:test, docstring: "help", labels: %i[x x])
      end.to raise_exception(Fast::Prometheus::InvalidLabelName)
    end

    it "rejects a String duplicating a Symbol name" do
      expect do
        TestMetric.new(:test, docstring: "help", labels: [:x, "x"])
      end.to raise_exception(Fast::Prometheus::InvalidLabelName)
    end
  end

  describe "label values" do
    let(:metric) { TestMetric.new(:test, docstring: "help", labels: [:v]) }

    it "stores valid UTF-8 as the caller's own object" do
      value = +"café"
      expect(metric.public_resolve(v: value).first.equal?(value)).to be(:==, true)
    end

    it "reinterprets BINARY bytes as UTF-8 and scrubs them" do
      expect(metric.public_resolve(v: "a\xffb".b)).to be(:==, ["a�b"])
    end

    it "transcodes another encoding" do
      expect(metric.public_resolve(v: "caf\xe9".dup.force_encoding("ISO-8859-1"))).to be(:==, ["café"])
    end

    it "normalizes a with_labels value the same way" do
      bound = metric.with_labels(v: "caf\xe9".dup.force_encoding("ISO-8859-1"))
      bound.touch
      expect(metric.values).to be(:==, { v: "café" } => 1.0)
    end
  end

  describe "#with_labels" do
    it "raises on unknown label name" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      expect { metric.with_labels(unknown: "get") }.to raise_exception(Fast::Prometheus::InvalidLabelSet)
    end

    it "shares storage with parent" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      bound = metric.with_labels(method: "get")
      bound.touch
      expect(metric.values).to be(:==, { method: "get" } => 1.0)
    end

    it "seeds its series on creation when fully bound" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      metric.with_labels(method: "get")
      expect(metric.values).to be(:==, { method: "get" } => 0.0)
    end
  end

  describe "#labels" do
    it "returns the declared label names" do
      metric = TestMetric.new(:test, docstring: "help", labels: %i[method status])
      expect(metric.labels).to be(:==, %i[method status])
    end

    it "returns a frozen copy the caller cannot grow" do
      names = %i[method]
      metric = TestMetric.new(:test, docstring: "help", labels: names)
      names << :status
      expect(metric.labels).to be(:==, %i[method])
      expect(metric.labels.frozen?).to be(:==, true)
    end

    it "no longer responds to label_names" do
      metric = TestMetric.new(:test, docstring: "help")
      expect(metric.respond_to?(:label_names)).to be(:==, false)
    end
  end

  describe "#init_label_set" do
    it "creates an absent series at zero" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      metric.init_label_set(method: "get")
      expect(metric.values).to be(:==, { method: "get" } => 0.0)
    end

    it "never resets a live series" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      metric.touch(labels: { method: "get" })
      metric.init_label_set(method: "get")
      expect(metric.values).to be(:==, { method: "get" } => 1.0)
    end

    it "raises InvalidLabelSet on an unknown label" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      expect { metric.init_label_set(bogus: "1") }.to raise_exception(Fast::Prometheus::InvalidLabelSet)
    end
  end

  describe "#get" do
    it "never creates a series" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      before = metric.values
      metric.get(labels: { method: "get" })
      expect(metric.values).to be(:==, before)
    end
  end

  describe "#resolve" do
    it "raises on missing label" do
      metric = TestMetric.new(:test, docstring: "help", labels: %i[method status])
      expect { metric.public_resolve(method: "get") }.to raise_exception(Fast::Prometheus::InvalidLabelSet)
    end

    it "resolves false per-call label to \"false\"" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:ok])
      expect(metric.public_resolve(ok: false)).to be(:==, ["false"])
    end

    it "resolves nil per-call label to \"\"" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:ok])
      expect(metric.public_resolve(ok: nil)).to be(:==, [""])
    end

    it "resolves false via with_labels identically to per-call labels" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:ok])
      metric.touch(labels: { ok: false })
      bound = metric.with_labels(ok: false)
      bound.touch
      expect(metric.values.keys.map { |h| h[:ok] }.sort).to be(:==, ["false"])
    end

    it "resolves nil via with_labels identically to per-call labels" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:ok])
      metric.touch(labels: { ok: nil })
      bound = metric.with_labels(ok: nil)
      bound.touch
      expect(metric.values.keys.map { |h| h[:ok] }.sort).to be(:==, [""])
    end

    it "raises InvalidLabelSet when key absent from both labels and presets" do
      metric = TestMetric.new(:test, docstring: "help", labels: %i[ok extra])
      expect { metric.public_resolve(ok: true) }.to raise_exception(Fast::Prometheus::InvalidLabelSet)
    end
  end

  describe "#store" do
    it "is not part of the public interface" do
      metric = TestMetric.new(:test, docstring: "help")
      expect(metric.respond_to?(:store)).to be(:==, false)
    end
  end

  describe "#raw_values" do
    it "is not part of the public interface" do
      metric = TestMetric.new(:test, docstring: "help")
      expect(metric.respond_to?(:raw_values)).to be(:==, false)
    end
  end

  describe "#values" do
    it "returns label-hash keyed data" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      metric.touch(labels: { method: "get" })
      expect(metric.values).to be(:==, { method: "get" } => 1.0)
    end
  end

  describe "#snapshot_values" do
    it "returns label-hash keyed frozen values, built under the store lock" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      metric.touch(labels: { method: "get" })
      expect(metric.snapshot_values).to be(:==, ["get"] => 1.0)
    end
  end

  describe "fiber-safety" do
    include Sus::Fixtures::Async::ReactorContext

    it "accumulates correctly under 500 concurrent tasks" do
      metric = TestMetric.new(:test, docstring: "help", labels: [:method])
      bound = metric.with_labels(method: "get")

      run_with_timeout do
        tasks = 500.times.map do
          Async do
            bound.touch
          end
        end

        tasks.each(&:wait)
      end

      expect(metric.values).to be(:==, { method: "get" } => 500.0)
    end
  end
end
