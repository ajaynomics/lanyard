require "test_helper"
require "yaml"
require "erb"
require "socket"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "test_helpers/agent_test_helper"

# How the Pi Durable sidecar is deployed (docs/agent.md): Node in the image,
# its own Kamal role beside web and job, reachable only through a Unix socket
# on the shared volume, and its callbacks admitted by the web role's alias.
# Read from the files a deploy loads, and run where a process is involved.
class AgentDeploymentTest < ActiveSupport::TestCase
  include AgentTestHelper

  SOCKET = "/rails/storage/agent/sidecar.sock".freeze

  def merged(destination)
    load = ->(path) { YAML.safe_load(ERB.new(Rails.root.join(path).read).result, aliases: true) }
    load.call("config/deploy.yml").deep_merge(load.call("config/deploy.#{destination}.yml"))
  end

  def destinations = Dir[Rails.root.join("config/deploy.*.yml").to_s].map { |path| File.basename(path)[/\Adeploy\.(.+)\.yml\z/, 1] }

  test "every destination runs the sidecar as its own private role beside web" do
    destinations.each do |destination|
      config = merged(destination)
      roles = config.fetch("servers")
      web, job, agent = roles.values_at("web", "job", "agent")

      assert agent, "#{destination} has no agent role"
      assert_equal "bin/agent-container", agent["cmd"], destination
      assert_equal false, agent["proxy"], "#{destination}: kamal-proxy must never route to the sidecar"
      assert_equal web.fetch("hosts"), agent.fetch("hosts"), "#{destination}: the sidecar must share web's volume and host"
      assert_empty agent.fetch("options", {}).keys & %w[publish p network-alias network], "#{destination}: the sidecar publishes nothing"
      assert_equal SOCKET, agent.dig("env", "clear", "AGENT_SOCKET"), destination
      assert_equal "http://#{web.dig('options', 'network-alias')}", agent.dig("env", "clear", "AGENT_RAILS_URL"), destination
      assert_equal "unix://#{SOCKET}", web.dig("env", "clear", "PI_DURABLE__SIDECAR_URL"), destination
      assert_includes config.fetch("volumes").join, ":/rails/storage", "#{destination}: the store must live on the volume"

      tokens = %w[PI_DURABLE__SIDECAR_TOKEN PI_DURABLE__RAILS_TOKEN]
      [ web, job, agent ].each { |role| assert_empty tokens - role.dig("env", "secret"), destination }
      assert_not_includes agent.dig("env", "secret"), "RAILS_MASTER_KEY", "#{destination}: the sidecar never needs the app's credentials"
      assert_not_includes web.dig("env", "secret"), "OPENAI_API_KEY", "#{destination}: the provider key is the sidecar's alone"
    end
  end

  test "the image carries Node and the locked sidecar packages" do
    dockerfile = Rails.root.join("Dockerfile").read

    assert_match(/^FROM docker\.io\/library\/node:\d+\.\d+\.\d+-bookworm-slim@sha256:\h{64} AS node$/, dockerfile, "Node is pinned to a release and its digest")
    assert_match(%r{^COPY --from=node /usr/local/bin/node /usr/local/bin/node$}, dockerfile)
    assert_match(/npm-cli\.js ci --ignore-scripts --omit=dev/, dockerfile, "packages come from agent/package-lock.json, scripts off")
    assert_match(/^CMD \["\.\/bin\/falcon"\]/, dockerfile, "web still runs Falcon; the sidecar is the agent role's command")
    assert_includes Rails.root.join(".dockerignore").read, "/agent/node_modules"
  end

  test "the client reaches the sidecar over a Unix socket" do
    Dir.mktmpdir("agent-socket") do |dir|
      path = File.join(dir, "sidecar.sock")
      server = UNIXServer.new(path)
      seen = Thread.new do
        client = server.accept
        head = +""
        head << client.gets until head.end_with?("\r\n\r\n")
        body = { id: 12, status: "done", entries: [], pendingInputs: [], usage: nil }.to_json
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
        head
      end
      install_sidecar_settings
      Rails.application.config.x.pi_durable = { sidecar_url: "unix://#{path}", sidecar_token: SIDECAR_TOKEN, rails_token: RAILS_TOKEN }

      result = DurableAssistants::PiDurable::Client.new.snapshot(synthetic_access, "12")

      assert_equal "done", result["status"]
      request = seen.value
      assert_match(%r{\AGET /v1/conversations/12\?actorId=alice&workspaceId=one HTTP/1\.1\r\n}, request)
      assert_includes request, "Authorization: Bearer #{SIDECAR_TOKEN}\r\n"
    ensure
      server&.close
      remove_sidecar_settings
    end
  end

  test "a socket URL must name an absolute socket path and nothing else" do
    install_sidecar_settings
    [ "unix://host/x.sock", "unix:relative.sock", "unix:///dir/", "unix:///x.sock?query=1", "ftp://127.0.0.1" ].each do |url|
      Rails.application.config.x.pi_durable = { sidecar_url: url, sidecar_token: SIDECAR_TOKEN, rails_token: RAILS_TOKEN }
      error = assert_raises(DurableAssistants::PiDurable::Client::Error, url) { DurableAssistants::PiDurable::Client.new.snapshot(synthetic_access, "12") }
      assert_equal 503, error.status, url
    end
  ensure
    remove_sidecar_settings
  end

  test "only the sidecar callbacks skip host authorization" do
    ok = ->(_env) { [ 200, {}, [ "ok" ] ] }
    guard = ActionDispatch::HostAuthorization.new(ok, [ "app.example" ], **Rails.application.config.host_authorization)
    call = ->(method, path) { guard.call(Rack::MockRequest.env_for("http://app-web#{path}", method: method)).first }

    %w[ /agent/accesses /agent/invocations /agent/frames /agent/syncs /agent/sign_ins ].each { assert_equal 200, call.("POST", it), it }
    assert_equal 403, call.("GET", "/agent/invocations")
    assert_equal 403, call.("POST", "/agents/1/conversations")
    assert_equal 403, call.("GET", "/conversations/1")
  end

  # bin/agent starts Node with a clean environment, so a setting the sidecar
  # reads that bin/agent does not pass is one nobody can set.
  test "every setting the sidecar's server reads reaches it through bin/agent" do
    read = Rails.root.join("agent/server.mjs").read.scan(/process\.env\.([A-Z][A-Z0-9_]*)/).flatten.uniq
    passed = Rails.root.join("bin/agent").read.scan(/^\s+(?:\$\{[A-Z_]+\+)?([A-Z][A-Z0-9_]*)=/).flatten

    # bin/agent-container owns the socket and forwards it to the sidecar's port.
    assert_empty read - passed - %w[AGENT_SOCKET], "read by agent/server.mjs, never passed by bin/agent"
    assert_includes passed, "AGENT_SHELL_NETWORK", "the scan has stopped seeing what bin/agent passes"
  end

  # bin/agent-container copied beside a stand-in bin/agent that answers /up as
  # the sidecar does: 503 store_already_owned until the old owner lets go.
  test "the container waits for the store's owner, then serves only its socket" do
    with_container do |run|
      pid, socket, released = run.call
      sleep 2.5
      assert_nil Process.wait(pid, Process::WNOHANG), "it gave up while the old owner still held the store"
      assert File.file?(socket), "it replaced the old owner's socket before it owned the store"

      FileUtils.touch(released)
      wait_for { File.socket?(socket) }
      response = DurableAssistants::PiDurable::UnixHTTP.new(socket).get("/v1/anything")
      assert_equal "200", response.code
      assert_equal "/v1/anything", JSON.parse(response.body).fetch("path")

      Process.kill("TERM", pid)
      _, status = Process.wait2(pid)
      assert_equal 0, status.exitstatus
      assert_not File.exist?(socket), "the socket outlived its sidecar"
    end
  end

  test "any other reason the sidecar is not ready stops the container" do
    with_container("FAKE_REASON" => "configuration_or_storage_failure") do |run|
      pid, socket, = run.call
      _, status = Timeout.timeout(20) { Process.wait2(pid) }
      assert_equal 1, status.exitstatus
      assert File.file?(socket), "a sidecar that never became ready touched the socket"
    end
  end

  private
    def wait_for(seconds = 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until yield
        flunk "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end

    def with_container(env = {})
      Dir.mktmpdir("agent-container") do |dir|
        FileUtils.mkdir_p(File.join(dir, "bin"))
        FileUtils.cp(Rails.root.join("bin/agent-container"), File.join(dir, "bin/agent-container"))
        File.write(File.join(dir, "bin/agent"), <<~JS)
          #!/usr/bin/env node
          const fs = require('node:fs');
          require('node:http').createServer((request, response) => {
            const reply = (status, body) => { response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(body)); };
            if (request.url !== '/up') return reply(200, { path: request.url });
            if (process.env.FAKE_REASON) return reply(503, { ready: false, reason: process.env.FAKE_REASON });
            fs.existsSync(process.env.FAKE_RELEASED) ? reply(200, { ready: true }) : reply(503, { ready: false, reason: 'store_already_owned' });
          }).listen(Number(process.env.AGENT_PORT), '127.0.0.1');
          process.on('SIGTERM', () => process.exit(0));
        JS
        FileUtils.chmod(0o755, File.join(dir, "bin/agent"))
        socket = File.join(dir, "sidecar.sock")
        File.write(socket, "an earlier owner's socket")
        released = File.join(dir, "released")
        port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
        pid = nil
        run = lambda do
          pid = Process.spawn({ "AGENT_PORT" => port.to_s, "AGENT_SOCKET" => socket, "AGENT_OWNER_WAIT" => "30",
                                "FAKE_RELEASED" => released }.merge(env), File.join(dir, "bin/agent-container"),
                              out: File::NULL, err: File::NULL, pgroup: true)
          [ pid, socket, released ]
        end
        yield run
      ensure
        if pid
          begin
            Process.kill("-KILL", pid)
            Process.wait(pid)
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          end
        end
      end
    end
end
