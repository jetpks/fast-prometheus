# frozen_string_literal: true

require "fast/prometheus"

spec = Gem.loaded_specs["fast-prometheus"]

unless spec
  puts "CHECK provenance: FAIL fast-prometheus not in Gem.loaded_specs"
  exit
end

gem_home = File.realpath(ENV.fetch("GEM_HOME"))
full_path = File.realpath(spec.full_gem_path)

if full_path == gem_home || full_path.start_with?("#{gem_home}#{File::SEPARATOR}")
  puts "CHECK provenance: PASS"
else
  puts "CHECK provenance: FAIL full_gem_path=#{full_path} is not under GEM_HOME=#{gem_home}"
end
