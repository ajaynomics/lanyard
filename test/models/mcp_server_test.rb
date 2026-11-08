require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"
require_relative "../test_helpers/fake_oauth_mcp"
require_relative "../test_helpers/concourse_test_helper"

class McpServerTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper
  include ConcourseTestHelper
  include ActiveJob::TestHelper
  DEFAULT_RESOLVER = McpServer::Address.resolver

  OAUTH_URL = "https://oauth.example.test/mcp".freeze

  setup do
    @agent = create_user.agents.sole
    @user = @agent.user
  end

  test "a name is a short slug, once per person and once per conversation" do
    assert @user.mcp_servers.create(name: "wiki_2", url: MCP_URL).persisted?
    assert_not @user.mcp_servers.new(name: "wiki_2", url: MCP_URL).valid?
    %w[ Wiki 2wiki wiki-two ].each { assert_not @user.mcp_servers.new(name: it, url: MCP_URL).valid?, it }
    assert @user.mcp_servers.new(name: "wiki", url: MCP_URL).valid?
    conversation = create_conversation(@agent)
    assert @user.mcp_servers.create(name: "wiki_2", url: MCP_URL, conversation: conversation).persisted?, "a conversation's own may share a name"
    assert_not @user.mcp_servers.new(name: "wiki_2", url: MCP_URL, conversation: conversation).valid?
  end

  test "a conversation uses the person's connectors and its own; its own replaces or switches off one of the same name" do
    conversation, other = create_conversation(@agent, durable_id: "1"), create_conversation(@agent, durable_id: "2")
    create_mcp_server(@agent, name: "wiki", tools: [ mcp_tool("search") ])
    create_mcp_server(@agent, name: "docs", tools: [ mcp_tool("read") ])
    create_mcp_server(@agent, name: "wiki", url: "https://other.example.test/mcp", tools: [ mcp_tool("find") ], conversation: conversation)
    create_mcp_server(@agent, name: "notes", tools: [ mcp_tool("jot") ], conversation: conversation)
    @user.mcp_servers.create!(name: "docs", enabled: false, conversation: conversation)

    assert_equal %w[ notes wiki ], conversation.connectors.map(&:name)
    assert_equal "https://other.example.test/mcp", conversation.connectors.last.url
    assert conversation.tool("mcp__wiki__find")
    assert_nil conversation.tool("mcp__wiki__search")
    assert_nil conversation.tool("mcp__docs__read")
    assert_equal %w[ docs wiki ], other.connectors.map(&:name)
    assert other.tool("mcp__wiki__search")
    assert_includes conversation.definition[:tools].pluck(:name), "mcp__notes__jot"

    assert_not @user.mcp_servers.new(name: "off", enabled: false).valid?, "only a conversation switches one off"
    assert_not @user.mcp_servers.new(name: "x", url: MCP_URL, conversation: create_conversation(create_user(name: "Eve").agents.sole)).valid?
  end

  test "outside development a person's connector cannot reach this server or its private network; the install's own may" do
    original, Rails.env = Rails.env, "production"
    [ "http://localhost:8080/mcp", "https://127.0.0.1/mcp", "https://[::1]/mcp", "https://10.0.0.5/mcp", "https://192.168.1.2/mcp",
      "https://169.254.169.254/latest", "https://0.0.0.0/mcp", "https://2130706433/mcp", "https://[::ffff:127.0.0.1]/mcp",
      "https://admin.localhost/mcp" ].each do |url|
      assert_not @user.mcp_servers.new(name: "a", url: url).valid?, url
    end
    assert @user.mcp_servers.new(name: "a", url: "https://mcp.example.test/mcp").valid?
    installed, Rails.application.config.x.install_connectors = Rails.application.config.x.install_connectors, { wiki: { url: "http://127.0.0.1:9100/mcp" } }
    assert @user.mcp_servers.new(name: "wiki", install: "wiki", url: "http://127.0.0.1:9100/mcp").valid?
  ensure
    Rails.env = original
    Rails.application.config.x.install_connectors = installed
  end

  test "outside development a public name that resolves to a private address is refused, and a public one is looked up once" do
    server = create_mcp_server(@agent, tools: [ mcp_tool("search") ])
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "found" } ] } } })
    original, Rails.env = Rails.env, "production"
    looked_up = []
    resolve_to = ->(address) { McpServer::Address.resolver = ->(host) { looked_up << host; [ address ] } }

    resolve_to.("10.0.0.5")
    failure = assert_raises(McpServer::Unreachable) { server.call_tool("search", {}) }
    assert_match(/mcp\.example\.test is on this server or its private network/, failure.message)
    %w[ 127.0.0.1 169.254.169.254 100.64.0.1 0.0.0.1 ::1 fd00::1 ::ffff:10.0.0.1 ].each do |address|
      assert McpServer::Address.internal?(address), address
    end

    resolve_to.("203.0.113.10")
    looked_up.clear
    server.call_tool("search", {})
    assert_equal [ "mcp.example.test" ], looked_up.uniq
    assert_not McpServer::Address.internal?("2001:db8::1")

    installed, Rails.application.config.x.install_connectors = Rails.application.config.x.install_connectors, { wiki: { url: MCP_URL } }
    assert_not @user.mcp_servers.new(name: "wiki", install: "wiki", url: MCP_URL).pinned?, "the install's own may be private"
  ensure
    Rails.env = original
    McpServer::Address.resolver = DEFAULT_RESOLVER
    Rails.application.config.x.install_connectors = installed if installed
  end

  test "a pinned request goes to the address checked, with the name kept for the Host header" do
    listener = TCPServer.new("127.0.0.1", 0)
    seen = Thread.new { connection = listener.accept; head = connection.readpartial(4096); connection.write("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"); connection.close; head }
    McpServer::Address.resolver = ->(_host) { [ "127.0.0.1" ] }
    McpServer::Address.singleton_class.alias_method :checked_internal?, :internal?
    McpServer::Address.define_singleton_method(:internal?) { |_address| false }
    WebMock.disable!

    response = Faraday.new("http://mcp.example.test:#{listener.addr[1]}") { McpServer::Address.pin(it) }.get("/mcp")
    assert_equal 204, response.status
    assert_match(/^Host: mcp\.example\.test/i, seen.value)
  ensure
    WebMock.enable!
    McpServer::Address.singleton_class.alias_method :internal?, :checked_internal?
    McpServer::Address.resolver = DEFAULT_RESOLVER
    listener&.close
  end

  test "the count is of every tool the agent sends, its skills and channels included" do
    @agent.skills.create!(name: "trip", description: "Plans trips.", body: "Steps")
    create_concourse_agent(@agent)
    room = Agent::TOOL_LIMIT - @agent.conversation.tools.size

    assert @user.mcp_servers.new(name: "wiki", url: MCP_URL, tools: Array.new(room) { mcp_tool("t#{it}") }).valid?
    server = @user.mcp_servers.new(name: "wiki", url: MCP_URL, tools: Array.new(room + 1) { mcp_tool("t#{it}") })
    assert_not server.valid?
    assert_match(/already has #{Agent::TOOL_LIMIT - room}/, server.errors.full_messages.to_sentence)
  end

  test "the token travels only over https, or plain http to this machine" do
    assert @user.mcp_servers.new(name: "a", url: "http://localhost:8080/mcp").valid?
    assert @user.mcp_servers.new(name: "a", url: "http://127.0.0.1/mcp").valid?
    assert_not @user.mcp_servers.new(name: "a", url: "http://mcp.example.test/mcp").valid?
    assert_not @user.mcp_servers.new(name: "a", url: "ftp://mcp.example.test").valid?
    assert_not @user.mcp_servers.new(name: "a", url: "not a url").valid?
  end

  test "the token is stored encrypted" do
    server = @user.mcp_servers.create!(name: "wiki", url: MCP_URL, token: "secret-token-1")

    assert_equal "secret-token-1", server.reload.token
    assert_not_includes server.ciphertext_for(:token), "secret-token-1"
  end

  test "a refresh lists the server's tools with the bearer token" do
    stub_mcp_server(tools: [ mcp_tool("search", annotations: { readOnlyHint: true },
      properties: { query: { type: "string" } }, required: %w[ query ]) ])
    server = @user.mcp_servers.create!(name: "wiki", url: MCP_URL, token: "secret-token-1")

    server.refresh

    assert_equal [ { "name" => "search", "description" => "Does search.",
      "input_schema" => { "type" => "object", "properties" => { "query" => { "type" => "string" } }, "required" => %w[ query ] },
      "annotations" => { "readOnlyHint" => true } } ], server.reload.tools
    assert_nil server.refresh_error
    assert_not server.refreshing?
    assert_requested :post, MCP_URL, headers: { "Authorization" => "Bearer secret-token-1" }, times: 3
  end

  test "a server that cannot be reached keeps its tools and says why" do
    server = create_mcp_server(@agent, tools: [ mcp_tool("search") ])
    stub_request(:post, MCP_URL).to_return(status: 401)

    server.refresh

    assert_equal %w[ search ], server.reload.tools.pluck("name")
    assert_equal "wiki needs you to sign in.", server.refresh_error
    assert server.needs_sign_in?
  end

  test "a server that would give the agent too many tools is found when needed instead, and cannot be loaded" do
    stub_mcp_server(tools: Array.new(Agent::TOOL_LIMIT) { mcp_tool("tool_#{it}") })
    server = @user.mcp_servers.create!(name: "wiki", url: MCP_URL)

    server.refresh

    assert_equal Agent::TOOL_LIMIT, server.reload.tools.size
    assert_not server.loaded?
    assert_not server.update(loaded: true)
    assert_match(/offers 64 tools; Assistant can have 64 in all and already has 12/, server.errors.full_messages.to_sentence)
  end

  test "signing in: discovery from the 401, registration, PKCE, the callback, and tokens kept encrypted" do
    fake = serve_fake
    server = @user.mcp_servers.create!(name: "fake", url: OAUTH_URL)

    authorization_url = server.sign_in_url
    query = Rack::Utils.parse_query(URI(authorization_url).query)
    assert authorization_url.start_with?("https://oauth.example.test/authorize?")
    assert_equal [ "http://localhost/connectors/callback" ], fake.registrations.sole["redirect_uris"]
    assert_equal "S256", query["code_challenge_method"]
    assert_equal OAUTH_URL, query["resource"]
    assert_equal query["state"], server.reload.oauth_state

    server.finish_sign_in(callback_from(fake, authorization_url))

    server.reload
    assert server.signed_in?
    assert_nil server.oauth_state
    assert_match(/\Aat-/, server.oauth_tokens["access_token"])
    assert server.oauth_tokens["expires_at"] > 59.minutes.from_now.to_i
    %i[ oauth_tokens oauth_client ].each { assert_not_includes server.ciphertext_for(it), "at-" }
    assert_not_includes server.ciphertext_for(:oauth_tokens), server.oauth_tokens["refresh_token"]

    server.refresh
    assert_equal %w[ echo ], server.reload.tools.pluck("name")
    assert_equal({ "content" => [ { "type" => "text", "text" => "echo: hi" } ] }, server.call_tool("echo", { "text" => "hi" }))
  end

  test "outside development signing in is pinned too: discovery and registration meet the same check" do
    serve_fake
    server = @user.mcp_servers.create!(name: "fake", url: OAUTH_URL)
    original, Rails.env = Rails.env, "production"
    looked_up = []

    McpServer::Address.resolver = ->(host) { looked_up << host; [ "192.168.1.20" ] }
    assert_raises(McpServer::Unreachable) { server.sign_in_url }

    McpServer::Address.resolver = ->(host) { looked_up << host; [ "203.0.113.10" ] }
    assert server.sign_in_url.start_with?("https://oauth.example.test/authorize?")
    assert_equal [ "oauth.example.test" ], looked_up.uniq
  ensure
    Rails.env = original
    McpServer::Address.resolver = DEFAULT_RESOLVER
  end

  test "a server that reads Client ID Metadata Documents gets this install's address as the client, with no registration" do
    original = Rails.application.config.x.app[:url]
    Rails.application.config.x.app[:url] = "https://agents.example.com"
    document = ->(url) do
      assert_equal "https://agents.example.com/connectors/client", url
      { client_id: url, **McpServer.client_metadata }.to_json
    end
    fake = serve_fake(client_documents: document)
    server = @user.mcp_servers.create!(name: "fake", url: OAUTH_URL)

    authorization_url = server.sign_in_url
    assert_equal "https://agents.example.com/connectors/client", Rack::Utils.parse_query(URI(authorization_url).query)["client_id"]
    assert_empty fake.registrations
    server.finish_sign_in(callback_from(fake, authorization_url))
    assert server.reload.signed_in?
    assert_equal "https://agents.example.com/connectors/client", fake.token_requests.last["client_id"]

    other = @user.mcp_servers.create!(name: "other", url: OAUTH_URL.sub("oauth.", "registers."))
    plain = FakeOauthMcp.new.tap { stub_request(:any, %r{\Ahttps://registers\.example\.test/}).to_rack(it) }
    assert_equal "client-1", Rack::Utils.parse_query(URI(other.sign_in_url).query)["client_id"], "a server without it gets a registration"
    assert_equal [ "https://agents.example.com/connectors/callback" ], plain.registrations.sole["redirect_uris"]
  ensure
    Rails.application.config.x.app[:url] = original
  end

  test "a server that lists its tools to anyone still sends a connector set up to sign in to its sign-in page" do
    fake = serve_fake(open_listing: true)
    server = @user.mcp_servers.create!(name: "fake", url: OAUTH_URL, oauth_scope: "files.read")

    server.refresh
    assert_equal %w[ echo ], server.reload.tools.pluck("name")
    assert_equal "needs_sign_in", server.status, "listing worked, but nothing may be called until the person signs in"

    authorization_url = server.sign_in_url
    assert authorization_url.start_with?("https://oauth.example.test/authorize?")
    assert_equal "files.read", Rack::Utils.parse_query(URI(authorization_url).query)["scope"]
    server.finish_sign_in(callback_from(fake, authorization_url))
    assert_equal "ok", server.reload.status
  end

  test "Google's issuer, named with a trailing slash, passes; no other issuer's does" do
    flow = MCP::Client::OAuth::Flow.new(provider: nil)
    assert_nil flow.send(:ensure_issuer_matches!, expected: "https://accounts.google.com/", returned: "https://accounts.google.com")
    assert_raises(MCP::Client::OAuth::Flow::AuthorizationError) { flow.send(:ensure_issuer_matches!, expected: "https://auth.example.test/", returned: "https://auth.example.test") }
    assert_raises(MCP::Client::OAuth::Flow::AuthorizationError) { flow.send(:ensure_issuer_matches!, expected: "https://accounts.google.com/", returned: "https://accounts.evil.test") }
  end

  test "a callback is used once, and a state that matches no sign-in is refused" do
    fake = serve_fake
    server = @user.mcp_servers.create!(name: "fake", url: OAUTH_URL)
    url = server.sign_in_url
    callback = callback_from(fake, url)

    assert_raises(McpServer::Unreachable) { server.finish_sign_in(callback.merge("state" => "forged")) }
    server.reload.finish_sign_in(callback)
    error = assert_raises(McpServer::Unreachable) { server.reload.finish_sign_in(callback) }
    assert_match(/matches no pending authorization/, error.message)
  end

  test "the token endpoint refuses a code redeemed without its PKCE verifier" do
    fake = serve_fake
    server = @user.mcp_servers.create!(name: "fake", url: OAUTH_URL)
    callback = callback_from(fake, server.sign_in_url)
    server.reload.update!(oauth_pending: server.oauth_pending.merge("code_verifier" => "x" * 43))

    error = assert_raises(McpServer::Unreachable) { server.finish_sign_in(callback) }
    assert_match(/PKCE verifier does not match/, error.message)
    assert_not server.reload.signed_in?
  end

  test "a token close to expiry is renewed before the call, and a rejected one is refreshed once and retried" do
    fake = serve_fake(expires_in: 30)
    server = signed_in(fake)
    first = server.oauth_tokens["access_token"]

    server.refresh
    renewed = server.reload.oauth_tokens["access_token"]
    assert_not_equal first, renewed
    assert_equal 1, fake.token_requests.count { it["grant_type"] == "refresh_token" }

    server.update!(oauth_tokens: server.oauth_tokens.merge("expires_at" => 1.hour.from_now.to_i))
    fake.expire!
    server.refresh
    assert_equal 2, fake.token_requests.count { it["grant_type"] == "refresh_token" }
    assert_equal %w[ echo ], server.reload.tools.pluck("name")
    assert_nil server.refresh_error
  end

  test "away from a person a lost sign-in asks for a new one rather than starting it" do
    fake = serve_fake
    server = signed_in(fake)
    server.update!(oauth_tokens: server.oauth_tokens.merge("refresh_token" => "revoked"))
    fake.expire!

    server.refresh

    assert_equal "signed needs you to sign in again.", server.reload.refresh_error
    assert_nil server.oauth_state, "no sign-in was started"
    assert_not server.signed_in?
  end

  test "a pasted client is used instead of registering, and signing out forgets the tokens only" do
    fake = serve_fake
    server = @user.mcp_servers.create!(name: "fake", url: OAUTH_URL, client_id: "my-app", client_secret: "shh")
    assert_equal({ "client_id" => "my-app", "client_secret" => "shh", "token_endpoint_auth_method" => "client_secret_post" }, server.oauth_client)

    query = Rack::Utils.parse_query(URI(server.sign_in_url).query)
    assert_equal "my-app", query["client_id"]
    assert_empty fake.registrations

    signed = signed_in(fake)
    signed.sign_out
    assert_not signed.reload.signed_in?
    assert signed.oauth_client.present?
  end

  test "a connector that needs sign-in offers none of its tools, nor counts them, until the person signs in again" do
    conversation = create_conversation(@agent)
    mail = create_mcp_server(@agent, name: "mail", tools: [ mcp_tool("send"), mcp_tool("read") ])
    signed_in_count = @agent.tool_count
    assert conversation.tool("mcp__mail__send")

    mail.sign_out
    assert_equal %w[ send read ], mail.reload.tools.pluck("name"), "still listed, for its settings to show"
    assert_nil conversation.reload.tool("mcp__mail__send")
    assert_equal signed_in_count - 2, @agent.reload.tool_count
    assert_empty conversation.agent.definition(conversation.tools)[:tools].pluck(:name).grep(/\Amcp__mail__/)

    mail.update!(loaded: false)
    assert_not_includes conversation.reload.tools.map(&:tool_name), "find_tools", "nothing to look up while it needs sign-in"

    mail.update!(loaded: true, oauth_tokens: { "access_token" => "t", "signed_in_at" => Time.current.to_i })
    assert conversation.reload.tool("mcp__mail__send")
    assert_equal signed_in_count, @agent.reload.tool_count
  end

  test "a connector set up to sign in needs it even when the server lists its tools to anyone" do
    server = @user.mcp_servers.create!(name: "gmail", url: MCP_URL, oauth_scope: "https://example.test/scope", tools: [], refreshed_at: Time.current)
    assert_equal "needs_sign_in", server.status

    server.update!(oauth_tokens: { "access_token" => "t", "signed_in_at" => Time.current.to_i })
    assert_equal "ok", server.status
  end

  test "status follows pi's /mcp: connected, listing, off, needs sign-in, failing, and no computer" do
    server = create_mcp_server(@agent, tools: [ mcp_tool("search") ])
    assert_equal "ok", server.status
    assert_not server.needs_attention?

    assert_equal "listing", @user.mcp_servers.create!(name: "new", url: MCP_URL).status
    server.update!(enabled: false)
    assert_equal "off", server.status
    server.update!(enabled: true, refresh_error: "Could not reach wiki: 503")
    assert_equal "failing", server.status
    assert server.needs_attention?
    server.update!(refresh_error: "wiki needs you to sign in.", sign_in_needed: true)
    assert_equal "needs_sign_in", server.status
    server.update!(token: "secret-token-1")
    assert_equal "failing", server.status, "a pasted token is not signed in again"

    command = @user.mcp_servers.create!(name: "files", command: "npx", tools: [ { "name" => "read" } ], refreshed_at: Time.current)
    assert_equal "no_computer", command.status(create_conversation(@agent))
    assert_equal "ok", command.status
  end

  test "a failed call marks the connector failing, and one that succeeds clears it; a tool's own error is not a failure" do
    server = create_mcp_server(@agent, tools: [ mcp_tool("search") ])
    stub_request(:post, MCP_URL).to_return(status: 503)
    assert_raises(McpServer::Unreachable) { server.call_tool("search", {}) }
    assert_match(/Could not reach wiki/, server.reload.refresh_error)
    assert_equal "failing", server.status

    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "no such page" } ], isError: true } } })
    server.call_tool("search", {})
    assert_nil server.reload.refresh_error
    assert_equal "ok", server.status
  end

  test "a call refused for sign-in forgets the tokens, so the connector needs sign-in" do
    fake = serve_fake
    server = signed_in(fake)
    server.update!(oauth_tokens: server.oauth_tokens.merge("refresh_token" => "revoked"))
    fake.expire!

    assert_raises(McpServer::SignInNeeded) { server.call_tool("echo", { "text" => "hi" }) }
    assert_not server.reload.signed_in?
    assert_equal "needs_sign_in", server.status
  end

  test "a page follows a change a person can see, not a token renewed before a call" do
    server = create_mcp_server(@agent, tools: [ mcp_tool("search") ])
    assert_no_enqueued_jobs(only: Turbo::Streams::BroadcastStreamJob) { server.update!(oauth_tokens: { "access_token" => "at-2" }) }
    assert_enqueued_jobs(1, only: Turbo::Streams::BroadcastStreamJob) { server.update!(refresh_error: "Could not reach wiki.") }
  end

  test "a Google gallery connector signs in with the instance's app, asks for offline access, and the person's own client overrides it" do
    with_google_app do
      serve_google
      gmail = @user.mcp_servers.create!(name: "gmail", **McpServer.gallery_attributes(:gmail))
      assert_nil gmail.oauth_client, "the row keeps only the app's name"

      query = Rack::Utils.parse_query(URI(gmail.sign_in_url).query)
      assert_equal "instance-id", query["client_id"]
      assert_equal "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.compose", query["scope"]
      assert_equal [ "offline", "consent select_account" ], query.values_at("access_type", "prompt"), "a second account picks its own"
      assert_equal "https://gmailmcp.googleapis.com/mcp/v1", query["resource"]

      mine = @user.mcp_servers.create!(name: "gmail_2", client_id: "my-google-app", **McpServer.gallery_attributes(:gmail))
      assert_equal "my-google-app", Rack::Utils.parse_query(URI(mine.sign_in_url).query)["client_id"]
    end
  end

  test "the instance's app goes only to the server its gallery entry names" do
    assert_not @user.mcp_servers.new(name: "evil", url: MCP_URL, oauth_app: "google").valid?
    assert @user.mcp_servers.new(name: "gmail", **McpServer.gallery_attributes(:gmail)).valid?
  end

  private
    def with_google_app
      x = Rails.application.config.x
      saved, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
      yield
    ensure
      x.connectors = saved
    end

    # Google's shape: the MCP server's metadata names accounts.google.com,
    # which publishes only an OpenID configuration and offers no registration.
    def serve_google
      stub_request(:post, "https://gmailmcp.googleapis.com/mcp/v1").to_return(status: 401,
        headers: { "WWW-Authenticate" => %(Bearer resource_metadata="https://gmailmcp.googleapis.com/.well-known/oauth-protected-resource/mcp/v1") })
      stub_request(:get, %r{\Ahttps://gmailmcp\.googleapis\.com/\.well-known/oauth-protected-resource}).to_return(
        headers: { "Content-Type" => "application/json" },
        body: { resource: "https://gmailmcp.googleapis.com/mcp/v1", authorization_servers: [ "https://accounts.google.com" ] }.to_json)
      stub_request(:get, "https://accounts.google.com/.well-known/oauth-authorization-server").to_return(status: 404)
      stub_request(:get, "https://accounts.google.com/.well-known/openid-configuration").to_return(
        headers: { "Content-Type" => "application/json" },
        body: { issuer: "https://accounts.google.com", authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
                token_endpoint: "https://oauth2.googleapis.com/token", code_challenge_methods_supported: %w[ plain S256 ],
                scopes_supported: %w[ openid email profile ] }.to_json)
    end

    def serve_fake(**options)
      FakeOauthMcp.new(**options).tap { |fake| stub_request(:any, %r{\Ahttps://oauth\.example\.test/}).to_rack(fake) }
    end

    # The person approves on the service's page, which sends them back with a code.
    def callback_from(fake, authorization_url)
      response = Rack::MockRequest.new(fake).get(authorization_url)
      Rack::Utils.parse_query(URI(response.location).query)
    end

    def signed_in(fake, name: "signed")
      server = @user.mcp_servers.create!(name: name, url: OAUTH_URL)
      server.finish_sign_in(callback_from(fake, server.sign_in_url))
      server.reload
    end
end
