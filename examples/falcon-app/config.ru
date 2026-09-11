# frozen_string_literal: true

require "fast/prometheus"
require "fast/prometheus/rack/instrumentation"
require "fast/prometheus/rack/exporter"

use Fast::Prometheus::Rack::Instrumentation, native: true
use Fast::Prometheus::Rack::Exporter

run lambda { |env|
  case env["PATH_INFO"]
  when "/"
    [200, { "content-type" => "text/plain" }, ["hello"]]
  when "/work"
    [200, { "content-type" => "text/plain" }, ["did work"]]
  else
    [404, { "content-type" => "text/plain" }, ["not found"]]
  end
}
