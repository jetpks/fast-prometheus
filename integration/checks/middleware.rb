# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/middleware/exporter"
require "async"
require "async/http/endpoint"
require "async/http/server"
require "async/http/client"
require "zlib"

HOST = "127.0.0.1"
PORT = 19_403

begin
  registry = Fast::Prometheus::Registry.new
  registry.counter(:mw_requests_total, docstring: "Total requests").increment(by: 5)

  middleware = Fast::Prometheus::Middleware::Exporter.new(
    Protocol::HTTP::Middleware::NotFound,
    registry: registry
  )

  endpoint = Async::HTTP::Endpoint.parse("http://#{HOST}:#{PORT}", protocol: Async::HTTP::Protocol::HTTP1)

  Async do
    bound = endpoint.bound
    server = Async::HTTP::Server.new(middleware, bound, protocol: endpoint.protocol, scheme: endpoint.scheme)
    server_task = server.run

    client = Async::HTTP::Client.new(endpoint)

    text_response = client.get("/metrics")
    text_ct = text_response.headers["content-type"]
    text_response.read
    text_response.close
    raise "text content-type mismatch: #{text_ct}" unless text_ct == Fast::Prometheus::Formats::Text::CONTENT_TYPE

    proto_response = client.get("/metrics", { "accept" => "application/vnd.google.protobuf" })
    proto_ct = proto_response.headers["content-type"]
    proto_response.read
    proto_response.close
    unless proto_ct == Fast::Prometheus::Formats::Protobuf::CONTENT_TYPE
      raise "protobuf content-type mismatch: #{proto_ct}"
    end

    gz_response = client.get("/metrics", { "accept-encoding" => "gzip" })
    content_encoding = gz_response.headers["content-encoding"].to_s
    compressed = gz_response.read
    gz_response.close
    raise "missing gzip content-encoding: #{content_encoding.inspect}" unless content_encoding.include?("gzip")

    decompressed = Zlib.gunzip(compressed)
    raise "gzip body did not decompress to expected metric" unless decompressed.include?("mw_requests_total 5.0")

    client.close
    server_task.stop
    bound.close
  end

  puts "CHECK middleware: PASS"
rescue StandardError => e
  puts "CHECK middleware: FAIL #{e.class}: #{e.message}"
end
