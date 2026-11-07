require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"
require_relative "../test_helpers/fake_oauth_mcp"

class McpServerTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  OAUTH_URL = "https://oauth.example.test/mcp".freeze

  setup do
    @bot = create_user.bots.sole
    @user = @bot.user
  end

  test "a name is a short slug, once per person and once per agent" do
    assert @user.mcp_servers.create(name: "wiki_2", url: MCP_URL).persisted?
    assert_not @user.mcp_servers.new(name: "wiki_2", url: MCP_URL).valid?
    %w[ Wiki 2wiki wiki-two ].each { assert_not @user.mcp_servers.new(name: it, url: MCP_URL).valid?, it }
    assert @user.mcp_servers.new(name: "wiki", url: MCP_URL).valid?
    agent = create_conversation(@bot)
    assert @user.mcp_servers.create(name: "wiki_2", url: MCP_URL, conversation: agent).persisted?, "an agent's own may share a name"
    assert_not @user.mcp_servers.new(name: "wiki_2", url: MCP_URL, conversation: agent).valid?
  end

  test "an agent uses the person's connectors and its own; its own replaces or switches off one of the same name" do
    agent, other = create_conversation(@bot, durable_id: "1"), create_conversation(@bot, durable_id: "2")
    create_mcp_server(@bot, name: "wiki", tools: [ mcp_tool("search") ])
    create_mcp_server(@bot, name: "docs", tools: [ mcp_tool("read") ])
    create_mcp_server(@bot, name: "wiki", url: "https://other.example.test/mcp", tools: [ mcp_tool("find") ], conversation: agent)
    create_mcp_server(@bot, name: "notes", tools: [ mcp_tool("jot") ], conversation: agent)
    @user.mcp_servers.create!(name: "docs", enabled: false, conversation: agent)

    assert_equal %w[ notes wiki ], agent.connectors.map(&:name)
    assert_equal "https://other.example.test/mcp", agent.connectors.last.url
    assert agent.tool("mcp__wiki__find")
    assert_nil agent.tool("mcp__wiki__search")
    assert_nil agent.tool("mcp__docs__read")
    assert_equal %w[ docs wiki ], other.connectors.map(&:name)
    assert other.tool("mcp__wiki__search")
    assert_includes agent.bot.definition(agent.tools)[:tools].pluck(:name), "mcp__notes__jot"

    assert_not @user.mcp_servers.new(name: "off", enabled: false).valid?, "only an agent switches one off"
    assert_not @user.mcp_servers.new(name: "x", url: MCP_URL, conversation: create_conversation(create_user(name: "Eve").bots.sole)).valid?
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
    server = create_mcp_server(@bot, tools: [ mcp_tool("search") ])
    stub_request(:post, MCP_URL).to_return(status: 401)

    server.refresh

    assert_equal %w[ search ], server.reload.tools.pluck("name")
    assert_equal "wiki needs you to sign in.", server.refresh_error
    assert server.needs_sign_in?
  end

  test "a server that would give the bot too many tools is refused on refresh" do
    stub_mcp_server(tools: Array.new(Bot::TOOL_LIMIT) { mcp_tool("tool_#{it}") })
    server = @user.mcp_servers.create!(name: "wiki", url: MCP_URL)

    server.refresh

    assert_empty server.reload.tools
    assert_match(/offers 64 tools; Durable Assistants can have 64 in all and already has 5/, server.refresh_error)
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
    assert_empty signed.tools
  end

  test "status follows pi's /mcp: connected, listing, off, needs sign-in, failing, and no computer" do
    server = create_mcp_server(@bot, tools: [ mcp_tool("search") ])
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
    assert_equal "no_computer", command.status(create_conversation(@bot))
    assert_equal "ok", command.status
  end

  test "a failed call marks the connector failing, and one that succeeds clears it; a tool's own error is not a failure" do
    server = create_mcp_server(@bot, tools: [ mcp_tool("search") ])
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
    server = create_mcp_server(@bot, tools: [ mcp_tool("search") ])
    assert_no_enqueued_jobs(only: Turbo::Streams::BroadcastStreamJob) { server.update!(oauth_tokens: { "access_token" => "at-2" }) }
    assert_enqueued_jobs(1, only: Turbo::Streams::BroadcastStreamJob) { server.update!(refresh_error: "Could not reach wiki.") }
  end

  private
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
