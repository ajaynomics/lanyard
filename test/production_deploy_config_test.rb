require "test_helper"
require "yaml"
require "erb"
require "uri"

# What the deployed estate must look like, read from the files a deploy
# actually loads. Kamal deep-merges config/deploy.yml with one
# config/deploy.<destination>.yml, so every rule here merges the same way and
# then asserts, for every destination file found: a destination added later is
# checked without anyone remembering to add it here. Each failure message says
# what broke rather than what the value should be.
class ProductionDeployConfigTest < ActiveSupport::TestCase
  def load_deploy(path) = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true)

  def base = load_deploy(Rails.root.join("config/deploy.yml"))

  def merged(destination) = base.deep_merge(load_deploy(Rails.root.join("config/deploy.#{destination}.yml")))

  def destinations
    names = Dir[Rails.root.join("config/deploy.*.yml").to_s].map { |path| File.basename(path)[/\Adeploy\.(.+)\.yml\z/, 1] }.sort
    assert_not_empty names, "no config/deploy.*.yml: every destination rule here would pass on nothing"
    names
  end

  def dockerfile = Rails.root.join("Dockerfile").read

  def gemfile = Rails.root.join("Gemfile").read

  def secrets_file(destination) = Rails.root.join(".kamal/secrets.#{destination}").read

  def resolved_names(destination) = secrets_file(destination).scan(/^([A-Z][A-Z0-9_]*)=/).flatten

  test "a destination is mandatory and the base carries no estate" do
    assert base.fetch("require_destination"),
      "a bare `kamal deploy` would resolve to whichever destination Kamal found first"

    %w[servers accessories proxy registry builder ssh env].each do |key|
      assert_not base.key?(key), <<~MESSAGE
        config/deploy.yml holds `#{key}`, which belongs to a destination.
        Kamal deep-merges a destination file over this one: hashes merge and
        arrays are replaced, but nothing can be removed. So anything estate-
        shaped here is inherited by every destination that comes after,
        including ones written by someone who never read this file.
      MESSAGE
    end
  end

  # An install adds its own destinations beside the example; each is checked
  # below without anyone remembering to list it here.
  test "the example destination an install copies is here, and is checked like any other" do
    assert_includes destinations, "example"
  end

  test "every destination is health checked at /up, which the app answers" do
    destinations.each do |destination|
      path = merged(destination).dig("proxy", "healthcheck", "path") || "/up"

      assert_equal "/up", path, "#{destination}: kamal-proxy checks #{path}"
    end
    assert_equal "/up", Rails.application.routes.url_helpers.rails_health_check_path
  end

  test "every role caps memory and sets memory-swap to match, so Docker cannot swap past the cap" do
    destinations.each do |destination|
      merged(destination).fetch("servers").each do |role, config|
        options = config.fetch("options", {})

        assert options["memory"].present?, "#{destination}/#{role} has no memory cap; the hosts are shared"
        assert_equal options["memory"], options["memory-swap"],
          "#{destination}/#{role} sets memory-swap different from memory, which lets it swap past the cap"
      end
    end
  end

  test "every destination runs Solid Queue in a job role beside web, and only there" do
    destinations.each do |destination|
      roles = merged(destination).fetch("servers")
      web = roles.fetch("web")
      job = roles.fetch("job")

      assert_equal "bin/jobs", job["cmd"], "#{destination} has no job role to run Solid Queue in"
      assert_equal false, job["proxy"], "#{destination}'s job role runs bin/jobs; there is no HTTP server behind it"
      assert_nil web["cmd"], "#{destination}: web must run the image's own CMD (Falcon)"
      assert_equal web.fetch("hosts"), job.fetch("hosts"),
        "#{destination}'s job role is not beside its web role, so they do not share one SQLite queue"
      assert_equal web.dig("env", "secret").sort, job.dig("env", "secret").sort,
        "#{destination}'s job role boots the whole app and needs every secret web needs"
      assert_equal web.dig("env", "clear", "DEPLOYMENT_ENVIRONMENT"), job.dig("env", "clear", "DEPLOYMENT_ENVIRONMENT"),
        "#{destination}'s job role reports a different environment than its web role"
    end
  end

  test "every role names the service and the destination its telemetry came from" do
    # One cell holds every destination's spans and logs. Without the resource
    # attribute staging and production are one indistinguishable pile; without
    # the service name the job role is a stranger in the trace view.
    destinations.each do |destination|
      merged(destination).fetch("servers").each do |role, server|
        clear = server.dig("env", "clear")

        assert clear["OTEL_SERVICE_NAME"].present?, "#{destination}/#{role} has no OTEL_SERVICE_NAME"
        assert_match(/(\A|,)deployment\.destination=#{Regexp.escape(destination)}(,|\z)/, clear["OTEL_RESOURCE_ATTRIBUTES"].to_s,
          "#{destination}/#{role} does not say which destination its telemetry came from")
      end
    end
  end

  test "every env.secret a role names is resolved by that destination's secrets file" do
    destinations.each do |destination|
      config = merged(destination)
      resolved = resolved_names(destination)

      config.fetch("servers").each do |role, server|
        # "NAME" or "ENV_NAME:SECRET_NAME": Kamal reads the secret by its
        # right-hand name, and a missing one fails the deploy after the build.
        names = server.dig("env", "secret").to_a.map { |entry| entry.split(":").last }
        assert_empty names - resolved, <<~MESSAGE
          #{destination}/#{role} consumes secrets .kamal/secrets.#{destination} does not define.
          Kamal would send the container an empty value, or refuse after building.
        MESSAGE
      end
      assert_empty Array(config.dig("registry", "password")) - resolved,
        "#{destination}: the registry password is never resolved"
    end
  end

  test "every secret a destination resolves is one a role consumes" do
    destinations.each do |destination|
      config = merged(destination)
      consumed = config.fetch("servers").values.flat_map { |role| role.dig("env", "secret").to_a }.map { |entry| entry.split(":").last }
      consumed += config.fetch("accessories", {}).values.flat_map { |accessory| accessory.dig("env", "secret").to_a }.map { |entry| entry.split(":").last }
      consumed += Array(config.dig("registry", "password"))

      assert_empty resolved_names(destination) - consumed, <<~MESSAGE
        #{destination} resolves these on every deploy and hands them to no role.
        Each one is a credentials lookup performed for nothing.
      MESSAGE
    end
  end

  test "a secrets file stores no value: every line resolves at deploy time" do
    destinations.each do |destination|
      secrets_file(destination).each_line do |raw|
        line = raw.strip
        next if line.empty? || line.start_with?("#", "export ")
        # The tailnet and loopback registries do not authenticate; Kamal still
        # wants the key.
        next if line == "KAMAL_REGISTRY_PASSWORD=unused"

        assert_match(/\A[A-Z][A-Z0-9_]*=([^$]*)\$\(/, line, <<~MESSAGE)
          .kamal/secrets.#{destination} has a line that is not a command substitution:

            #{line[/\A[A-Z0-9_]+/]}=...

          This file is committed. Every value in it must resolve at deploy time,
          so that the file can be read by anyone and holds nothing when it is.
        MESSAGE
      end
    end
  end

  test "the master key resolves from Passbolt on every destination" do
    destinations.each do |destination|
      assert_match(/^RAILS_MASTER_KEY=\$\(passbolt get resource --id [0-9a-f-]{36} -j \| jq -r \.password\)$/, secrets_file(destination),
        "#{destination}: RAILS_MASTER_KEY is the one secret every role needs")
    end
  end

  test "secrets never ride in clear env, and the settings production requires are stated or in credentials" do
    destinations.each do |destination|
      merged(destination).fetch("servers").each do |role, server|
        clear = server.dig("env", "clear").keys

        assert_empty clear & %w[GLITCHTIP__DSN OIDC__CLIENT_SECRET OTEL_EXPORTER_OTLP_HEADERS RAILS_MASTER_KEY],
          "#{destination}/#{role}: a secret in clear env is committed in the clear"
        next if server["cmd"] == "bin/agent-container" # the Pi Durable sidecar (docs/agent.md)

        assert_includes clear, "APP__URL", "#{destination}/#{role}: production_secrets.rb requires app.url, and so does config.hosts"
        assert_includes clear, "OIDC__ISSUER", "#{destination}/#{role}"
        assert_includes clear, "OIDC__CALLBACK_URI",
          "#{destination}/#{role}: Ajent rejects a redirect_uri it has not registered, so this and the Doorkeeper application are edited together"
      end
    end
  end

  test "the origin Rails authorizes is the one kamal-proxy routes" do
    destinations.each do |destination|
      config = merged(destination)
      app_host = URI.parse(config.dig("servers", "web", "env", "clear", "APP__URL")).host

      assert_equal app_host, config.dig("proxy", "host"),
        "#{destination}: kamal-proxy routes one hostname and production.rb derives config.hosts from APP__URL; " \
        "if they disagree every proxied request is a 403"
      callback = config.dig("servers", "web", "env", "clear", "OIDC__CALLBACK_URI")
      assert_equal "https://#{app_host}/auth/ajent/callback", callback if callback
    end
  end

  test "production.rb derives hosts from the app url and spares only the health path and Campfire's webhook" do
    source = Rails.root.join("config/environments/production.rb").read

    assert_match(/Rails\.app\.creds\.option\(:app, :url\)/, source,
      "config.hosts names a hostname literally; a destination's origin is stated once, in its deploy file, and derived here")
    assert_includes source, 'config.host_authorization = { exclude: ->(request) { request.path == "/up" || request.path.start_with?("/campfire/") } }',
      "only the health path kamal-proxy polls, and the webhook whose path holds its own secret, may skip DNS rebinding protection"
  end

  test "the proxy sends traffic to the port Falcon binds" do
    destinations.each do |destination|
      config = merged(destination)

      assert_equal "80", config.dig("servers", "web", "env", "clear", "PORT"), "#{destination}: bin/falcon binds PORT"
      assert_not config.fetch("proxy").key?("app_port"), "#{destination}: app_port is omitted so kamal-proxy uses 80"
    end
  end

  test "the image starts Falcon on 80, not Puma or Thruster" do
    assert_match(/^CMD \["\.\/bin\/falcon"\]/, dockerfile)
    assert_match(/^EXPOSE 80/, dockerfile)
    assert_no_match(/thrust|puma/i, dockerfile)
    assert_includes gemfile, 'gem "falcon"'
    assert_not_includes gemfile, "puma"
    assert_not_includes gemfile, "thruster"
  end

  test "the web container migrates the database before it serves" do
    command = dockerfile[/^CMD \["([^"]+)"/, 1]
    entrypoint = Rails.root.join("bin/docker-entrypoint").read

    assert_includes entrypoint, %("${1}" = "#{command}")
    assert_includes entrypoint, "db:prepare"
  end

  test "no deploy file passes a dead REVISION build arg" do
    ([ "config/deploy.yml" ] + destinations.map { |destination| "config/deploy.#{destination}.yml" }).each do |path|
      assert_no_match(/REVISION:/, Rails.root.join(path).read, path)
    end
  end

  test "excludes prohibited deployment privileges" do
    # No container this app deploys may reach the host's Docker daemon, share
    # its network or process namespace, or run privileged. Any one of these
    # turns a container escape into a host compromise, on hosts shared with
    # every other tenant.
    forbidden = [ "docker.sock", "network: host", "pid: host", "privileged: true" ]

    ([ "config/deploy.yml" ] + destinations.map { |destination| "config/deploy.#{destination}.yml" }).each do |path|
      source = Rails.root.join(path).read.downcase

      forbidden.each do |value|
        assert_not_includes source, value, "#{path} grants `#{value}`. No app here needs any of them."
      end
    end
  end
end
