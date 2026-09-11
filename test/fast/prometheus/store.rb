# frozen_string_literal: true

require "fast/prometheus"

describe Fast::Prometheus::Store do
  let(:store) { Fast::Prometheus::Store.new }

  it "reads and writes by key" do
    store[:a] = 1.0
    expect(store[:a]).to be(:==, 1.0)
  end

  it "returns nil for an absent key" do
    expect(store[:missing]).to be_nil
  end

  it "returns a copy of the data for iteration" do
    store[:a] = 1.0
    copy = store.to_h
    expect(copy).to be(:==, { a: 1.0 })

    copy[:b] = 2.0
    expect(store.to_h).to be(:==, { a: 1.0 })
  end

  describe "#synchronize" do
    it "returns the block's value" do
      expect(store.synchronize { 42 }).to be(:==, 42)
    end

    it "is reentrant on the same thread" do
      result = store.synchronize { store.synchronize { :inner } }
      expect(result).to be(:==, :inner)
    end

    it "serializes access across threads" do
      store[:count] = 0
      threads = 20.times.map do
        Thread.new { store.synchronize { store[:count] += 1 } }
      end
      threads.each(&:join)
      expect(store[:count]).to be(:==, 20)
    end
  end
end
