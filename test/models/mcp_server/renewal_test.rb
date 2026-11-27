require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/fake_oauth_mcp"

# A connector whose refresh token works once (rotating_refresh, Slack's) is
# renewed without holding SQLite's one write lock while the service answers:
# it claims the refresh token in a short transaction, asks with none open,
# and saves only if the row still holds the token it claimed. A real SQLite
# file with production's settings (5 s busy wait), and a token endpoint on
# loopback that can stall or refuse, marked rotating as a gallery entry.
class McpServer::RenewalTest < ActiveSupport::TestCase
  include AgentTestHelper

  # Fixture transactions would share one connection between the threads,
  # and hold a write lock of their own.
  self.use_transactional_tests = false

  setup do
    @saved = ActiveRecord::Base.connection_db_config
    @path = Rails.root.join("tmp/renewal-#{Process.pid}.sqlite3").to_s
    primary = ActiveRecord::Base.configurations.configs_for(env_name: "production", name: "primary")
    config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", primary.configuration_hash.merge(database: @path))
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) { load Rails.root.join("db/schema.rb") }
    end
    ActiveRecord::Base.establish_connection(config)

    @fake = FakeOauthMcp.new
    @stall, @refusal, @token_hit, @bearers = 0, nil, Queue.new, []
    loopback(->(env) {
      if env["PATH_INFO"] == "/token" && (@stall.positive? || @refusal)
        @token_hit << true
        sleep @stall
        next @refusal if @refusal
      end
      @bearers << env["HTTP_AUTHORIZATION"] if env["PATH_INFO"] == "/mcp"
      @fake.call(env)
    })
    x = Rails.application.config.x
    @connectors, x.connectors = x.connectors, x.connectors.to_h.deep_merge(
      gallery: { rotating: { label: "Rotating", url: "http://127.0.0.1:#{@port}/mcp", rotating_refresh: true } })
    @user = create_user
    @connector = sign_in(@user.mcp_servers.create!(name: "fake", url: "http://127.0.0.1:#{@port}/mcp"))
    @connector.update!(oauth_tokens: @connector.oauth_tokens.merge("expires_at" => 1.minute.ago.to_i))
    @expired = "Bearer #{@connector.oauth_tokens["access_token"]}"
    @fake.token_requests.clear
  end

  teardown do
    Rails.application.config.x.connectors = @connectors if @connectors
    @listener&.close
    ActiveRecord::Base.establish_connection(@saved)
    FileUtils.rm_f(Dir["#{@path}*"])
  end

  test "only Slack's gallery entry is marked rotating; the rest renew as the gem does" do
    gallery = Rails.application.config_for(:connectors)[:gallery]
    assert_equal %i[ slack ], gallery.select { |_, entry| entry[:rotating_refresh] }.keys
    assert McpServer.new(**McpServer.gallery_attributes(:slack)).rotating_refresh?
    assert_not McpServer.new(**McpServer.gallery_attributes(:github)).rotating_refresh?
    assert_not McpServer.new(**McpServer.gallery_attributes(:gmail)).rotating_refresh?
    assert @connector.rotating_refresh?
  end

  test "a write elsewhere in the app goes through at once while the service is slow to renew" do
    @stall = 3
    renewing = in_thread { call_tool }
    @token_hit.pop

    took = seconds { User.where(id: @user.id).update_all(updated_at: Time.current) } # tenancy-ok: the test's own user, as any request would write it
    assert_operator took, :<, 1, "the write waited on the renewal"
    assert_equal "echo: hi", renewing.value.dig("content", 0, "text")
  end

  test "of two calls that find the token expired, one renews and the other is told to try again, sending nothing with the expired token" do
    @stall = 2
    renewing = in_thread { call_tool }
    @token_hit.pop

    error = assert_raises(McpServer::Unreachable) { call_tool }
    assert_equal "fake's sign-in is being renewed; try again in a few seconds.", error.message
    assert_equal "echo: hi", renewing.value.dig("content", 0, "text")
    assert_equal 1, @fake.token_requests.count { it["grant_type"] == "refresh_token" }, "one refresh, not one per call"
    assert_not_includes @bearers, @expired
  end

  test "an answer that comes back after newer tokens were saved does not overwrite them" do
    newer = sign_in(@user.mcp_servers.create!(name: "other", url: "http://127.0.0.1:#{@port}/mcp")).oauth_tokens
    @stall = 2
    renewing = in_thread { call_tool }
    @token_hit.pop

    took = seconds { McpServer.find(@connector.id).update!(oauth_tokens: newer) } # tenancy-ok: the test's own connector, as a new sign-in saves it
    assert_operator took, :<, 1, "the save waited on the renewal"
    assert_equal "echo: hi", renewing.value.dig("content", 0, "text")
    assert_equal newer.slice("access_token", "refresh_token"), @connector.reload.oauth_tokens.slice("access_token", "refresh_token")
  end

  test "a renewal the service turns away is never tried again, even after two minutes: the person signs in again" do
    @refusal = [ 503, {}, [] ]
    error = assert_raises(McpServer::SignInNeeded) { call_tool }
    assert_equal "fake needs you to sign in again.", error.message
    assert @connector.reload.sign_in_needed?

    @refusal = nil
    travel McpServer::Renewal::CLAIM_LASTS + 1.second do
      assert_raises(McpServer::SignInNeeded) { call_tool }
    end
    assert_equal 1, @token_hit.size, "the refresh token was sent once"
    assert_not_includes @bearers, @expired
  end

  test "a 401 from the server while another call renews sends no second refresh" do
    expiring_soon
    @stall = 2
    renewing = in_thread { call_tool }
    @token_hit.pop
    @fake.expire!

    error = assert_raises(McpServer::Renewing) { call_tool }
    assert_equal "fake's sign-in is being renewed; try again in a few seconds.", error.message
    assert_equal "echo: hi", renewing.value.dig("content", 0, "text")
    assert_empty @token_hit, "no second refresh"
    assert_equal 1, @fake.token_requests.count { it["grant_type"] == "refresh_token" }
  end

  test "a refresh with no answer in time is never sent again; once the access token expires, sign in again" do
    expiring_soon
    @stall = McpServer::Renewal::TIMEOUT + 2
    assert_equal "echo: hi", call_tool.dig("content", 0, "text"), "the access token still works"
    assert_equal "echo: hi", call_tool.dig("content", 0, "text")
    sent = @bearers.size

    travel McpServer::Renewal::CLAIM_LASTS + 1.minute do
      error = assert_raises(McpServer::SignInNeeded) { call_tool }
      assert_equal "fake needs you to sign in again.", error.message
      assert_raises(McpServer::SignInNeeded) { call_tool }
    end
    assert_equal 1, @token_hit.size, "the refresh token was sent once"
    assert_not_includes @bearers.drop(sent), @expired, "nothing was sent with the expired token"

    @stall = 0
    sign_in(McpServer.find(@connector.id)) # tenancy-ok: the test's own connector, as the person signing in again
    assert_nil @connector.reload.refresh_claim
    assert_equal "echo: hi", call_tool.dig("content", 0, "text")
  end

  test "a refresh that could not connect was never sent, so the claim is let go and the next call renews" do
    refused = stub_request(:post, "http://127.0.0.1:#{@port}/token").to_raise(Errno::ECONNREFUSED)
    error = assert_raises(McpServer::Renewing) { call_tool }
    assert_equal "fake's sign-in is being renewed; try again in a few seconds.", error.message
    assert_nil @connector.reload.refresh_claim

    remove_request_stub(refused)
    assert_equal "echo: hi", call_tool.dig("content", 0, "text")
    assert_equal 1, @fake.token_requests.count { it["grant_type"] == "refresh_token" }
    assert_not_includes @bearers, @expired
  end

  test "a refresh token the service says was already used asks for a new sign-in" do
    @refusal = [ 400, { "content-type" => "application/json" }, [ { error: "invalid_grant" }.to_json ] ]
    assert_raises(McpServer::SignInNeeded) { call_tool }
    assert @connector.reload.sign_in_needed?
    assert_nil @connector.oauth_tokens
    assert_not_includes @bearers, @expired
  end

  private
    def call_tool = McpServer.find(@connector.id).call_tool("echo", { text: "hi" }) # tenancy-ok: the test's own connector, read afresh as a second request would

    # Still good, but due for renewal (McpServer::RENEW_BEFORE).
    def expiring_soon
      @connector.update!(oauth_tokens: @connector.oauth_tokens.merge("expires_at" => 50.seconds.from_now.to_i))
    end

    def sign_in(connector)
      authorize = Net::HTTP.get_response(URI(connector.sign_in_url))
      connector.finish_sign_in(Rack::Utils.parse_query(URI(authorize["location"]).query))
      connector
    end

    def in_thread(&work)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection(&work)
      rescue => error
        error
      end
    end

    def seconds
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    def loopback(app)
      @listener = TCPServer.new("127.0.0.1", 0)
      @port = @listener.addr[1]
      Thread.new do
        loop { Thread.new(@listener.accept) { serve(app, it) } }
      rescue IOError
        nil
      end
    end

    # Just enough HTTP/1.1 for the `mcp` gem's Faraday: one request per connection.
    def serve(app, socket)
      method, target = socket.gets.to_s.split(" ", 3)
      return unless target
      headers = {}
      while (header = socket.gets) && header != "\r\n"
        key, value = header.split(":", 2)
        headers[key.strip.downcase] = value.strip
      end
      env = Rack::MockRequest.env_for("http://127.0.0.1:#{@port}#{target}", method: method, input: socket.read(headers["content-length"].to_i).to_s)
      headers.each { |key, value| env[key == "content-type" ? "CONTENT_TYPE" : "HTTP_#{key.upcase.tr("-", "_")}"] = value }
      status, response_headers, body = app.call(env)
      out = body.each.to_a.join
      socket.write("HTTP/1.1 #{status} X\r\n" + response_headers.map { |key, value| "#{key}: #{value}\r\n" }.join +
        "Content-Length: #{out.bytesize}\r\nConnection: close\r\n\r\n" + out)
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close
    end
end
