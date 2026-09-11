# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/rack/exporter"
require "fast/prometheus/rack/instrumentation"
require "zlib"

begin
  registry = Fast::Prometheus::Registry.new
  registry.counter(:rack_requests_total, docstring: "Total requests").increment(by: 5)

  app = ->(_env) { [200, { "content-type" => "text/plain" }, ["hi"]] }
  exporter = Fast::Prometheus::Rack::Exporter.new(app, registry: registry)
  stack = Fast::Prometheus::Rack::Instrumentation.new(exporter, registry: registry)

  status, headers, body = stack.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/metrics")
  unless status == 200 && headers["content-type"] == Fast::Prometheus::Formats::Text::CONTENT_TYPE
    raise "text status/content-type mismatch: #{status} #{headers['content-type']}"
  end
  raise "text body missing metric" unless body.join.include?("rack_requests_total 5.0")

  status, headers, = stack.call(
    "REQUEST_METHOD" => "GET", "PATH_INFO" => "/metrics", "HTTP_ACCEPT" => "application/vnd.google.protobuf"
  )
  unless status == 200 && headers["content-type"] == Fast::Prometheus::Formats::Protobuf::CONTENT_TYPE
    raise "protobuf content-type mismatch: #{headers['content-type']}"
  end

  status, headers, body = stack.call(
    "REQUEST_METHOD" => "GET", "PATH_INFO" => "/metrics", "HTTP_ACCEPT_ENCODING" => "gzip"
  )
  unless headers["content-encoding"] == "gzip"
    raise "missing gzip content-encoding: #{headers['content-encoding'].inspect}"
  end

  decompressed = Zlib.gunzip(body.join)
  raise "gzip body did not decompress to expected metric" unless decompressed.include?("rack_requests_total 5.0")

  status, _headers, body = stack.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/other")
  raise "pass-through mismatch: #{status} #{body.join}" unless status == 200 && body.join == "hi"

  counter = registry.get(:http_server_requests_total)
  n = counter.get(labels: { method: "GET", status: "200" })
  raise "counter not recorded: #{n}" unless n.to_i == 4

  histogram = registry.get(:http_server_request_duration_seconds)
  count = histogram.count(labels: { method: "GET", status: "200" })
  raise "histogram not recorded: #{count}" unless count == 4

  leaked = $LOADED_FEATURES.grep(%r{/(protocol-http|async|rack|protocol-rack)-\d})
  raise "leaked deps: #{leaked}" unless leaked.empty?

  puts "CHECK rack: PASS"
rescue StandardError => e
  puts "CHECK rack: FAIL #{e.class}: #{e.message}"
end
