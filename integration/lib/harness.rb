# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

module Integration
  # Builds/installs a fast-prometheus gem artifact into an isolated GEM_HOME,
  # then runs each check script in its own child ruby process against that
  # install. Never puts the checkout's lib/ on any child's load path.
  class Harness
    REPO_ROOT = File.expand_path("../..", __dir__)
    CHECKS_DIR = File.expand_path("../checks", __dir__)
    RUBY = RbConfig.ruby

    OPT_IN_ENTRIES = [
      ["formats/text", "require-formats-text"],
      ["formats/protobuf", "require-formats-protobuf"],
      ["middleware/exporter", "require-middleware-exporter"],
      ["middleware/instrumentation", "require-middleware-instrumentation"],
      ["otlp/http_exporter", "require-otlp-http-exporter"],
      ["otlp/grpc_exporter", "require-otlp-grpc-exporter"],
      ["otlp/push", "require-otlp-push"]
    ].freeze

    ALL_CHECK_IDS = (
      %w[provenance core-require-io-free] +
      OPT_IN_ENTRIES.map(&:last) +
      %w[metric-surface registry text-promtool protobuf-roundtrip middleware
         e2e-scrape e2e-otlp-http e2e-otlp-grpc]
    ).freeze

    def initialize(gem_file: nil, e2e_required: ENV["E2E_REQUIRED"] == "1", out: $stdout)
      @given_gem_file = gem_file
      @e2e_required = e2e_required
      @out = out
      @lines = []
    end

    def run
      Dir.mktmpdir("fpc-integration") do |root|
        @root = root
        gem_file = @given_gem_file ? File.expand_path(@given_gem_file) : build_gem(root)

        unless gem_file
          fail_all!("gem build failed")
          return finish
        end

        gem_home = File.join(root, "gemhome")
        FileUtils.mkdir_p(gem_home)

        unless install_gem(gem_file, gem_home)
          fail_all!("gem install failed")
          return finish
        end

        @env = base_env(gem_home)

        run_script("provenance.rb", ["provenance"])
        run_script("require_core.rb", ["core-require-io-free"])
        OPT_IN_ENTRIES.each do |entry, id|
          run_script("require_entry.rb", [id], [entry, id])
        end
        run_script("behavioral_surface.rb", %w[metric-surface registry text-promtool protobuf-roundtrip])
        run_script("middleware.rb", ["middleware"])
        run_script("e2e_scrape.rb", ["e2e-scrape"])
        run_script("e2e_otlp_http.rb", ["e2e-otlp-http"])
        run_script("e2e_otlp_grpc.rb", ["e2e-otlp-grpc"])
      end

      finish
    end

    private

    def build_gem(root)
      gemspec = File.join(REPO_ROOT, "fast-prometheus.gemspec")
      output = File.join(root, "fast-prometheus.gem")
      _stdout, stderr, status = Open3.capture3("gem", "build", gemspec, "--output", output, chdir: REPO_ROOT)
      unless status.success?
        @out.puts "# gem build failed:\n#{stderr}"
        return nil
      end
      output
    end

    def install_gem(gem_file, gem_home)
      env = ENV.to_h.merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home)
      %w[BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH RUBYOPT RUBYLIB].each { |k| env.delete(k) }
      _stdout, stderr, status = Open3.capture3(
        env, "gem", "install", gem_file,
        "--install-dir", gem_home, "--no-document", "--conservative",
        chdir: @root
      )
      unless status.success?
        @out.puts "# gem install failed:\n#{stderr}"
        return false
      end
      true
    end

    def base_env(gem_home)
      env = ENV.to_h.merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home)
      %w[BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH RUBYOPT RUBYLIB].each { |k| env.delete(k) }
      env["PROMETHEUS_BIN"] = ENV["PROMETHEUS_BIN"] || "/opt/homebrew/bin/prometheus"
      env["PROMTOOL_BIN"] = ENV["PROMTOOL_BIN"] || "/opt/homebrew/bin/promtool"
      env
    end

    def run_script(script_name, expected_ids, args = [])
      path = File.join(CHECKS_DIR, script_name)
      stdout, stderr, status = Open3.capture3(@env, RUBY, path, *args, chdir: @root)

      check_lines = stdout.each_line.map(&:chomp).select { |l| l.start_with?("CHECK ") }
      seen_ids = check_lines.filter_map { |l| l[/^CHECK ([\w-]+):/, 1] }
      missing = expected_ids - seen_ids

      unless missing.empty?
        detail = stderr.split("\n").last(5).join(" | ")
        detail = "exit #{status.exitstatus}" if detail.empty?
        missing.each { |id| check_lines << "CHECK #{id}: FAIL script #{script_name} did not report (#{detail})" }
      end

      @lines.concat(check_lines)
    end

    def fail_all!(reason)
      ALL_CHECK_IDS.each { |id| @lines << "CHECK #{id}: FAIL #{reason}" }
    end

    def finish
      @lines.each { |l| @out.puts l }

      results = @lines.filter_map { |l| l.match(/^CHECK ([\w-]+): (PASS|FAIL|SKIP)/) }
      fail_count = results.count { |m| m[2] == "FAIL" }
      skip_count = results.count { |m| m[2] == "SKIP" }

      ok = fail_count.zero? && !(@e2e_required && skip_count.positive?)

      @out.puts "INTEGRATION: #{ok ? 'PASS' : 'FAIL'}"
      ok
    end
  end
end
