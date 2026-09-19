# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/exposition"
require "protocol/http/headers"
require "zlib"

describe Fast::Prometheus::Exposition do
  let(:registry) do
    registry = Fast::Prometheus::Registry.new
    registry.counter(:requests_total, docstring: "Total requests").increment(by: 5)
    registry
  end
  let(:text) { Fast::Prometheus::Formats::Text::CONTENT_TYPE }
  let(:protobuf) { Fast::Prometheus::Formats::Protobuf::CONTENT_TYPE }

  def content_type(accept)
    Fast::Prometheus::Exposition.render(registry, accept: accept, accept_encoding: nil).last["content-type"]
  end

  def content_encoding(accept_encoding)
    _, headers = Fast::Prometheus::Exposition.render(registry, accept: nil, accept_encoding: accept_encoding)
    headers["content-encoding"]
  end

  describe "format negotiation" do
    it "serves text when protobuf is not listed" do
      [nil, "", "*/*", "text/plain;version=0.0.4", "application/json"].each do |accept|
        expect(content_type(accept)).to be(:==, text)
      end
    end

    it "serves protobuf whatever the case and parameters of the media type" do
      ["application/vnd.google.protobuf",
       "APPLICATION/VND.GOOGLE.PROTOBUF",
       " application/vnd.google.protobuf ;encoding=delimited",
       "text/plain;q=0.5, application/vnd.google.protobuf;q=0.7"].each do |accept|
        expect(content_type(accept)).to be(:==, protobuf)
      end
    end

    it "matches the media type whole, not as a substring" do
      expect(content_type('text/plain;foo="application/vnd.google.protobuf"')).to be(:==, text)
      expect(content_type("application/vnd.google.protobuf.other")).to be(:==, text)
    end

    it "prefers the higher q, and protobuf on a tie" do
      expect(content_type("application/vnd.google.protobuf;q=0, text/plain")).to be(:==, text)
      expect(content_type("application/vnd.google.protobuf;q=0.1, text/plain;q=0.9")).to be(:==, text)
      expect(content_type("application/vnd.google.protobuf;q=0.9, text/plain;q=0.1")).to be(:==, protobuf)
      expect(content_type("application/vnd.google.protobuf;q=0.5, text/plain;q=0.5")).to be(:==, protobuf)
    end

    it "reads a header it cannot parse as no preference at all" do
      expect(content_type(";;;,,,q=")).to be(:==, text)
    end

    it "reads a member of any length" do
      junk = "a" * 100_000

      expect(content_type("#{junk},application/vnd.google.protobuf")).to be(:==, protobuf)
    end

    it "reads a Protocol::HTTP header value as the list it is" do
      headers = Protocol::HTTP::Headers.new
      headers["accept"] = "application/vnd.google.protobuf;q=0.7,text/plain;q=0.5"

      expect(content_type(headers["accept"])).to be(:==, protobuf)
    end
  end

  describe "content coding negotiation" do
    it "gzips when gzip is acceptable, whatever its case and position" do
      ["gzip", "GZIP", "deflate, gzip;q=0.5", "gzip, deflate, br"].each do |accept_encoding|
        expect(content_encoding(accept_encoding)).to be(:==, "gzip")
      end
    end

    it "does not gzip when gzip is absent or refused" do
      [nil, "br", "notgzipping", "gzip;q=0", "identity;q=1, gzip;q=0"].each do |accept_encoding|
        expect(content_encoding(accept_encoding)).to be_nil
      end
    end

    it "gzips the negotiated body" do
      body, headers = Fast::Prometheus::Exposition.render(registry, accept: nil, accept_encoding: "gzip")

      expect(headers["content-type"]).to be(:==, text)
      expect(Zlib.gunzip(body)).to be(:==, Fast::Prometheus::Formats::Text.render(registry.collect))
    end
  end
end
