# frozen_string_literal: true

require "fast/prometheus"
require "reference"
require "fast/prometheus/rack/exporter"
require "rack/lint"
require "rack/mock_request"
require "zlib"

describe Fast::Prometheus::Rack::Exporter do
  let(:registry) { Fast::Prometheus::Registry.new }
  let(:delegate) { ->(_env) { [200, { "content-type" => "text/plain" }, ["hi"]] } }

  before do
    registry.counter(:requests_total, docstring: "Total requests").increment(by: 5)
    registry.gauge(:temperature, docstring: "Temperature").set(22.5)
  end

  def app
    ::Rack::Lint.new(Fast::Prometheus::Rack::Exporter.new(::Rack::Lint.new(delegate), registry: registry))
  end

  def request
    ::Rack::MockRequest.new(app)
  end

  describe "GET /metrics" do
    it "returns text content type and parseable body" do
      response = request.get("/metrics")

      expect(response.status).to be(:==, 200)
      expect(response.content_type).to be(:==, "text/plain; version=0.0.4; charset=utf-8")
      expect(response.body).to be(:==, <<~TEXT)
        # HELP requests_total Total requests
        # TYPE requests_total counter
        requests_total 5.0
        # HELP temperature Temperature
        # TYPE temperature gauge
        temperature 22.5
      TEXT
    end
  end

  describe "GET /metrics with protobuf Accept" do
    it "returns protobuf content type and decodable body" do
      response = request.get("/metrics", "HTTP_ACCEPT" => "application/vnd.google.protobuf")

      expect(response.status).to be(:==, 200)
      expect(response.content_type).to be(:==, Fast::Prometheus::Formats::Protobuf::CONTENT_TYPE)
      body = response.body
      expect(body.bytesize).to be(:>, 0)

      offset = 0
      families = []
      while offset < body.bytesize
        msg_len, new_offset = decode_varint(body, offset)
        message = body[new_offset, msg_len]
        family = Io::Prometheus::Client::MetricFamily.decode(message)
        families << family
        offset = new_offset + msg_len
      end
      expect(families.length).to be(:>=, 2)
    end
  end

  describe "non-metrics path" do
    it "passes through to delegate" do
      response = request.get("/other")

      expect(response.status).to be(:==, 200)
      expect(response.body).to be(:==, "hi")
    end
  end

  describe "non-GET method" do
    it "passes through to delegate" do
      response = request.post("/metrics")

      expect(response.status).to be(:==, 200)
      expect(response.body).to be(:==, "hi")
    end
  end

  describe "gzip" do
    it "compresses body when Accept-Encoding includes gzip" do
      response = request.get("/metrics", "HTTP_ACCEPT_ENCODING" => "gzip")

      expect(response.status).to be(:==, 200)
      expect(response.headers["content-encoding"]).to be(:==, "gzip")
      decompressed = Zlib.gunzip(response.body)
      expect(decompressed).to be(:==, <<~TEXT)
        # HELP requests_total Total requests
        # TYPE requests_total counter
        requests_total 5.0
        # HELP temperature Temperature
        # TYPE temperature gauge
        temperature 22.5
      TEXT
    end

    it "does not compress when no gzip in Accept-Encoding" do
      response = request.get("/metrics")

      expect(response.headers.key?("content-encoding")).to be(:==, false)
    end
  end

  def decode_varint(data, offset)
    result = 0
    shift = 0
    loop do
      byte = data.getbyte(offset)
      offset += 1
      result |= (byte & 0x7f) << shift
      break if (byte & 0x80).zero?

      shift += 7
    end
    [result, offset]
  end
end
