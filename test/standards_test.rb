require "test_helper"
require "yaml"
require "erb"

# The shared project standard (omakase-template/STANDARDS.md), held by a test
# rather than by prose. This file is copied verbatim into every app: anything
# app-specific is derived, never edited in, so a diff between two apps' copies
# is itself drift. Change the standard in the template, then copy it out.
class StandardsTest < ActiveSupport::TestCase
  RAILS_REF = "c9e85dbe297e248dd2f217d04f84a94881ac046a"

  test "S1 the app serves through Falcon, with jobs in their own role" do
    assert_match(/^gem "falcon"/, gemfile)
    assert_not gemfile.match?(/^\s*gem "(puma|thruster)"/), "Falcon replaces Puma and Thruster"
    assert root.join("bin/falcon").executable?
    dockerfile = root.join("Dockerfile").read
    assert_match(%r{CMD \[.*bin/falcon}, dockerfile)
    # Falcon's stack (io-endpoint) compiles the openssl gem, and CI never builds
    # the image: without the headers the first deploy is where this fails.
    assert_match(/apt-get install[^\n]*\blibssl-dev\b/, dockerfile.gsub("\\\n", " "), "the Dockerfile installs libssl-dev to build the openssl gem")
    assert root.join("bin/jobs").executable?
    assert_not root.join("config/puma.rb").exist?, "config/puma.rb configures a server the app does not run"
  end

  test "S2 the app runs the shared edge Rails pin with 8.2 defaults" do
    assert_match(/^gem "rails", github: "rails\/rails", ref: "#{RAILS_REF}"/, gemfile)
    assert_match(/config\.load_defaults 8\.2/, root.join("config/application.rb").read)
  end

  test "S3 settings are read through Rails.app.creds, never a hand-rolled secret helper" do
    sources = Dir[root.join("{app,config,lib}/**/*.{rb,yml}")].map { |path| [ path, File.read(path) ] }

    helpers = sources.filter_map { |path, body| path if body.match?(/def (self\.)?secret\(/) }
    assert_empty helpers, "a hand-rolled secret reader duplicates Rails.app.creds"

    assert sources.any? { |_, body| body.include?("Rails.app.creds.option(") }, "no setting is read through Rails.app.creds"
    assert_not root.join("app/services").exist?, "no service layer"
  end

  test "S4 .env.example lists every setting read through creds" do
    read = Dir[root.join("{app,config,lib}/**/*.{rb,yml,erb}")].flat_map do |path|
      File.read(path).scan(/creds\.(?:option|require)\(\s*:(\w+)\s*,\s*:(\w+)/).map { |service, key| "#{service}__#{key}".upcase }
    end.to_set
    listed = root.join(".env.example").readlines.filter_map { |line| line[/\A([A-Z][A-Z0-9_]*)=/, 1] }.to_set

    assert_empty read - listed, "read through creds but absent from .env.example"
    assert root.join("test/env_example_test.rb").exist?, "copy env_example_test.rb from the template"
  end

  # Rails 8.2 reads .env itself, for Rails.app.creds in development only. The
  # dotenv gem's one remaining effect is loading a developer's .env into the
  # test suite, so tests pass or fail by what is on one laptop.
  test "S4 no dotenv gem: Rails reads .env itself, and tests stay hermetic" do
    assert_not gemfile.match?(/^\s*gem "dotenv"/), "drop the dotenv gem"
  end

  test "S5 bin/ci is the whole contract, including browser tests and a production boot" do
    ci = root.join("config/ci.rb").read
    steps = ci.lines.grep(/^\s*step /).join

    assert_match(/bin\/rails test:system/, steps, "browser tests belong in the local checklist")
    assert_match(/RAILS_ENV=production.*bin\/rails runner/, steps, "CI must prove the app boots in production")
    assert_match(/brakeman.*--exit-on-warn/, steps)
    %w[bin/rubocop bin/bundler-audit importmap bin/rails\ test db:seed:replant].each do |step|
      assert_includes steps, step
    end

    workflows = Dir[root.join(".{gitea,github}/workflows/ci.yml")]
    assert_equal 1, workflows.size, "exactly one CI workflow"
    runs = YAML.load_file(workflows.first).fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }.filter_map { |step| step["run"] }
    tests = runs.grep(/rails test|rubocop|brakeman|bundler-audit/)
    assert_empty tests, "CI runs checks bin/ci does not own: #{tests.join(' | ')}"
    assert runs.any? { |run| run.match?(/(^|\s)bin\/ci(\s|$)/) }, "CI must run bin/ci"
  end

  test "S6 tests cannot reach the network" do
    assert_match(/^\s*gem "webmock"/, gemfile)
    assert_match(/WebMock\.disable_net_connect!\(allow_localhost: true/, root.join("test/test_helper.rb").read)
  end

  test "S7 ownership scoping is enforced by a source scan" do
    assert root.join("test/tenancy_scoping_test.rb").exist?
  end

  test "S8 deploy hooks live where Kamal runs them, with no samples" do
    hooks = root.join(".kamal/hooks")
    %w[pre-build pre-deploy].each { |hook| assert hooks.join(hook).executable?, "#{hook} missing or not executable" }
    assert_empty Dir[hooks.join("*.sample")], "Kamal's samples are noise in the repo"
    assert_empty Dir[root.join(".kamal/*")].select { |path| File.file?(path) && !File.basename(path).start_with?("secrets") },
      "a hook outside .kamal/hooks never runs"
    assert root.join("test/deploy_gate_test.rb").exist?
  end

  test "S9 deploy config is tested" do
    assert root.join("test/production_deploy_config_test.rb").exist?
  end

  test "S10 the client IP arrives through the tunnel and nothing more is trusted" do
    assert root.join("test/trusted_proxies_test.rb").exist?
    trusting = Dir[root.join("config/**/*.rb")].select { |path| File.read(path).include?("trusted_proxies") }
    assert_empty trusting, "Cloudflare's ranges also carry other customers' Workers; " \
                           "behind the tunnel Rails' default proxies are the whole list"
  end

  test "S11 backups prove their restore" do
    scripts = Dir[root.join("ops/backup/*")].map { |path| File.basename(path) }
    assert scripts.any? { |name| name.end_with?("-backup.sh") }
    assert scripts.any? { |name| name.end_with?("-restore.sh") }
    assert Dir[root.join("test/**/*backup*_test.rb")].any?, "no test runs backup then restore"

    backup = Dir[root.join("ops/backup/*-backup.sh")].map { |path| File.read(path) }.join
    production = YAML.load(ERB.new(root.join("config/database.yml").read).result, aliases: true).fetch("production")
    production.each_value do |db|
      name = File.basename(db.fetch("database"), ".sqlite3")
      assert_includes backup, name, "the backup script does not snapshot the #{name} database"
    end
  end

  test "S12 agents, the domain, and people each have their document" do
    %w[AGENTS.md CONTEXT.md README.md].each do |doc|
      assert root.join(doc).exist?, "#{doc} missing"
      assert_operator root.join(doc).read.length, :>, 400, "#{doc} is a stub"
    end
  end

  private
    def root = Rails.root
    def gemfile = @gemfile ||= root.join("Gemfile").read
end
