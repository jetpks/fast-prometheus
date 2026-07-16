# frozen_string_literal: true

require "fast_prometheus_client"
require "fast_prometheus_client/middleware/exporter"
require "async"
require "async/http/endpoint"
require "async/http/server"
require "async/http/client"
require "sus/fixtures/async/scheduler_context"
require "zlib"

describe FastPrometheusClient::Middleware::Exporter do
  include Sus::Fixtures::Async::SchedulerContext

  let(:registry) { FastPrometheusClient::Registry.new }
  let(:endpoint) { Async::HTTP::Endpoint.parse("http://localhost:0", protocol: Async::HTTP::Protocol::HTTP1) }
  let(:delegate) { Protocol::HTTP::Middleware::NotFound }

  before do
    registry.counter(:requests_total, docstring: "Total requests").increment(by: 5)
    registry.gauge(:temperature, docstring: "Temperature").set(22.5)
  end

  def middleware
    FastPrometheusClient::Middleware::Exporter.new(delegate, registry: registry)
  end

  def server_and_client
    bound = endpoint.bound
    server = Async::HTTP::Server.new(middleware, bound, protocol: endpoint.protocol, scheme: endpoint.scheme)
    server_task = server.run

    client = Async::HTTP::Client.new(
      bound.local_address_endpoint,
      protocol: endpoint.protocol,
      scheme: endpoint.scheme,
      authority: endpoint.authority,
      retries: 0
    )

    [server, server_task, bound, client]
  end

  def with_server
    _server, server_task, bound, client = server_and_client
    begin
      yield client
    ensure
      client.close
      server_task.stop
      server_task.wait_all
      bound.close
    end
  end

  describe "GET /metrics" do
    it "returns text content type and parseable body" do
      with_server do |client|
        request = Protocol::HTTP::Request["GET", "/metrics"]
        response = client.call(request)

        expect(response.status).to be(:==, 200)
        expect(response.headers["content-type"]).to be(:==, "text/plain; version=0.0.4; charset=utf-8")
        body = response.read
        expect(body).to be(:==, <<~TEXT
          # HELP requests_total Total requests
          # TYPE requests_total counter
          requests_total 5.0
          # HELP temperature Temperature
          # TYPE temperature gauge
          temperature 22.5
        TEXT
        )
        response.close
      end
    end
  end

  describe "GET /metrics with protobuf Accept" do
    it "returns protobuf content type and decodable body" do
      with_server do |client|
        request = Protocol::HTTP::Request[
          "GET",
          "/metrics",
          { "accept" => "application/vnd.google.protobuf" }
        ]
        response = client.call(request)

        expect(response.status).to be(:==, 200)
        protobuf_ct = "application/vnd.google.protobuf; proto=io.prometheus.client.MetricFamily; encoding=delimited"
        expect(response.headers["content-type"]).to be(:==, protobuf_ct)
        body = response.read
        expect(body).to be(:!=, nil)
        expect(body.bytesize).to be(:>, 0)
        response.close

        # Verify it decodes as varint-framed MetricFamily messages
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
  end

  describe "non-metrics path" do
    it "passes through to delegate" do
      with_server do |client|
        request = Protocol::HTTP::Request["GET", "/other"]
        response = client.call(request)

        expect(response.status).to be(:==, 404)
        response.close
      end
    end
  end

  describe "gzip" do
    it "compresses body when Accept-Encoding includes gzip" do
      with_server do |client|
        request = Protocol::HTTP::Request[
          "GET",
          "/metrics",
          { "accept-encoding" => "gzip" }
        ]
        response = client.call(request)

        expect(response.status).to be(:==, 200)
        expect(response.headers["content-encoding"]).to be(:==, ["gzip"])
        compressed = response.read
        decompressed = Zlib.gunzip(compressed)
        expect(decompressed).to be(:==, <<~TEXT
          # HELP requests_total Total requests
          # TYPE requests_total counter
          requests_total 5.0
          # HELP temperature Temperature
          # TYPE temperature gauge
          temperature 22.5
        TEXT
        )
        response.close
      end
    end

    it "does not compress when no gzip in Accept-Encoding" do
      with_server do |client|
        request = Protocol::HTTP::Request["GET", "/metrics"]
        response = client.call(request)

        expect(response.headers["content-encoding"]).to be_nil
        response.close
      end
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
