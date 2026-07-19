# frozen_string_literal: true

describe Fast::Prometheus do
  it "is a module" do
    expect(subject).to be_a(Module)
  end

  it "has a valid version" do
    expect(Fast::Prometheus::VERSION).to be(:match?, /\A\d+\.\d+\.\d+\z/)
  end
end
