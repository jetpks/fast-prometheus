# frozen_string_literal: true

describe Fast::Prometheus do
  it "is a module" do
    expect(subject).to be_a(Module)
  end

  it "has a valid version" do
    expect(Gem::Version.correct?(Fast::Prometheus::VERSION)).to be == true
  end
end
