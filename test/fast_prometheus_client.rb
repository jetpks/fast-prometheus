# frozen_string_literal: true

describe FastPrometheusClient do
  it "is a module" do
    expect(subject).to be_a(Module)
  end

  it "has a valid version" do
    expect(FastPrometheusClient::VERSION).to be(:match?, /\A\d+\.\d+\.\d+\z/)
  end
end
