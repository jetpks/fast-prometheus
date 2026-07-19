# frozen_string_literal: true

entry, id = ARGV

begin
  require "fast/prometheus"
  require "fast/prometheus/#{entry}"
  puts "CHECK #{id}: PASS"
rescue LoadError, StandardError => e
  puts "CHECK #{id}: FAIL #{e.class}: #{e.message}"
end
