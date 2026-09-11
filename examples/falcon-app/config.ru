# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/middleware/instrumentation"
require "fast/prometheus/middleware/exporter"
require "protocol/http/middleware"
require "protocol/rack/constants"

app = Protocol::HTTP::Middleware.for do |request|
  case request.path
  when "/"
    Protocol::HTTP::Response[200, {}, ["hello"]]
  when "/work"
    Protocol::HTTP::Response[200, {}, ["did work"]]
  else
    Protocol::HTTP::Response[404, {}, ["not found"]]
  end
end

app = Fast::Prometheus::Middleware::Instrumentation.new(app, native: true)
app = Fast::Prometheus::Middleware::Exporter.new(app)

# Falcon's config.ru is a Rack boundary; protocol-rack injects the original
# Protocol::HTTP::Request under this env key so the middleware above can use it directly.
run lambda { |env|
  response = app.call(env[Protocol::Rack::PROTOCOL_HTTP_REQUEST])
  [response.status, response.headers.to_h, response.body]
}
