require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"
require_relative "../test_helpers/fake_oauth_mcp"

class ConnectorsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  OAUTH_URL = "https://oauth.example.test/mcp".freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @bot = @user.bots.sole
    @agent = create_conversation(@bot)
    @fake = FakeOauthMcp.new
    stub_request(:any, %r{\Ahttps://oauth\.example\.test/}).to_rack(@fake)
  end
  teardown { remove_sidecar_settings }

  test "a connector with a token is added for all agents and its tools are listed away from the request" do
    assert_enqueued_jobs 1, only: McpServerRefreshJob do
      post connectors_path, params: { connector: { name: "wiki", url: MCP_URL, token: "secret-token-1" } }
    end
    assert_redirected_to connectors_path
    assert_equal "secret-token-1", @user.mcp_servers.global.sole.token

    stub_mcp_server(tools: [ mcp_tool("search", description: "Searches the wiki.") ])
    perform_enqueued_jobs
    get connectors_path
    assert_select "#connectors .list__item", /search.*Searches the wiki.*Asks you first/m
    assert_select "#connectors", text: /secret-token-1/, count: 0
  end

  test "adding a connector that asks for sign-in goes to the service, and its callback signs in" do
    post connectors_path, params: { connector: { name: "fake", url: OAUTH_URL, conversation_id: @agent.id } }

    assert_response :redirect
    assert response.location.start_with?("https://oauth.example.test/authorize?")
    connector = @agent.mcp_servers.sole
    approved = Rack::MockRequest.new(@fake).get(response.location).location
    assert approved.start_with?("http://localhost/connectors/callback?")

    assert_enqueued_with(job: McpServerRefreshJob, args: [ connector ]) { get URI(approved).request_uri }
    assert_redirected_to conversation_connectors_path(@agent)
    assert connector.reload.signed_in?
    perform_enqueued_jobs
    get conversation_connectors_path(@agent)
    assert_select "#connectors", /Signed in.*Sign out/m
    assert_select "#connectors .list__item", /echo/
  end

  test "a callback whose state matches no sign-in of this person's is refused" do
    post connectors_path, params: { connector: { name: "fake", url: OAUTH_URL } }
    approved = URI(Rack::MockRequest.new(@fake).get(response.location).location)
    query = Rack::Utils.parse_query(approved.query)

    get connectors_callback_path(code: query["code"], state: "forged")
    assert_redirected_to connectors_path
    assert_match(/doesn't match one you started/, flash[:alert])

    get connectors_callback_path(code: query["code"])
    assert_match(/doesn't match one you started/, flash[:alert])
    assert_not @user.mcp_servers.sole.signed_in?
  end

  test "signing out forgets the tokens and offers sign-in again" do
    post connectors_path, params: { connector: { name: "fake", url: OAUTH_URL } }
    get URI(Rack::MockRequest.new(@fake).get(response.location).location).request_uri
    assert @user.mcp_servers.sole.signed_in?
    connector = @user.mcp_servers.sole

    delete connector_sign_in_path(connector)
    assert_not connector.reload.signed_in?
    get connectors_path
    assert_select "form[action='#{connector_sign_in_path(connector)}'] button", "Sign in"
  end

  test "a server that needs no sign-in just lists its tools" do
    stub_mcp_server(tools: [ mcp_tool("search") ])

    assert_enqueued_jobs 1, only: McpServerRefreshJob do
      post connectors_path, params: { connector: { name: "wiki", url: MCP_URL } }
    end
    assert_redirected_to connectors_path
    assert_match(/needs no sign-in/, flash[:notice])
  end

  test "pi's mcp.json entries are accepted as pasted, remote ones only, with literal values" do
    json = { mcpServers: { docs: { url: MCP_URL, headers: { "Authorization" => "Bearer abc", "X-Team" => "one" } },
                           linear: { url: OAUTH_URL, oauth: { clientId: "my-app", clientSecret: "shh", scope: "read" } } } }.to_json
    post connectors_path, params: { connector: { json: json, conversation_id: @agent.id } }

    docs, linear = @agent.mcp_servers.to_a
    assert_equal({ "Authorization" => "Bearer abc", "X-Team" => "one" }, docs.request_headers)
    assert docs.authorized_by_header?
    assert_equal [ "my-app", "read" ], [ linear.oauth_client["client_id"], linear.oauth_scope ]
    assert_not_includes linear.ciphertext_for(:oauth_client), "shh"

    {
      { files: { command: "npx", args: [ "server" ] } } => "files: Only remote (URL) servers for now.",
      { gh: { url: MCP_URL, headers: { "Authorization" => "Bearer ${GITHUB_TOKEN}" } } } => "gh: uses ${…} or !command; paste the value itself.",
      { gh: { url: MCP_URL, oauth: { clientSecret: "!pass show gh" } } } => "gh: uses ${…} or !command; paste the value itself.",
      { gh: { url: MCP_URL, oauth: { clientRegistration: "cimd" } } } => /client ID metadata document/,
      { old: { url: MCP_URL, type: "sse" } } => "old: uses sse; only http servers work here.",
      [ 1 ] => /Paste an object of servers/
    }.each do |entry, message|
      post connectors_path, params: { connector: { json: entry.to_json } }
      assert_match message.is_a?(Regexp) ? message : /\A#{Regexp.escape(message)}\z/, flash[:alert]
    end
    assert_equal 2, @user.mcp_servers.count
  end

  test "an agent's entry with no address switches one of the person's connectors off for that agent only" do
    create_mcp_server(@bot, name: "wiki", tools: [ mcp_tool("search") ])
    other = create_conversation(@bot, durable_id: "13")

    post connectors_path, params: { connector: { json: { wiki: { enabled: false } }.to_json, conversation_id: @agent.id } }
    assert_redirected_to conversation_connectors_path(@agent)
    assert_nil @agent.tool("mcp__wiki__search")
    assert other.tool("mcp__wiki__search")
    get conversation_connectors_path(@agent)
    assert_select "#connectors", /Off for this agent/

    delete connector_path(@agent.mcp_servers.sole)
    assert @agent.tool("mcp__wiki__search")
  end

  # The owner's proof of pi's hot reload: Rails sends the whole definition with
  # every message, so a connector added, or switched off, changes the next turn.
  test "a connector created or switched off changes the agent's next message, globally and for one agent" do
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .with { sent << JSON.parse(it.body)["definition"]["tools"].pluck("name") }.to_return(status: 202, body: { id: 1 }.to_json)
    say = ->(text) { post conversation_submissions_path(@agent), params: { content: text, request_id: SecureRandom.uuid } }
    say.("first run")
    assert_empty sent.last.grep(/\Amcp__/)

    post connectors_path, params: { connector: { name: "wiki", url: MCP_URL, token: "t" } }
    post connectors_path, params: { connector: { name: "notes", url: MCP_URL, token: "t", conversation_id: @agent.id } }
    stub_mcp_server(tools: [ mcp_tool("search") ])
    perform_enqueued_jobs
    say.("with connectors")
    assert_equal %w[ mcp__notes__search mcp__wiki__search ], sent.last.grep(/\Amcp__/).sort

    patch connector_path(@user.mcp_servers.global.sole), params: { connector: { enabled: false } }
    patch connector_path(@agent.mcp_servers.sole), params: { connector: { enabled: false } }
    say.("without them")
    assert_empty sent.last.grep(/\Amcp__/)
    assert_equal 3, sent.size
  end

  test "someone else's connectors and agents are not found" do
    mallory = create_user(name: "Mallory").bots.sole
    theirs = create_mcp_server(mallory)
    their_agent = create_conversation(mallory, durable_id: "66")

    post connectors_path, params: { connector: { name: "wiki", url: MCP_URL, token: "t", conversation_id: their_agent.id } }
    assert_response :not_found
    get conversation_connectors_path(their_agent)
    assert_response :not_found
    [ -> { delete connector_path(theirs) }, -> { patch connector_path(theirs), params: { connector: { enabled: false } } },
      -> { post connector_sign_in_path(theirs) }, -> { delete connector_sign_in_path(theirs) }, -> { post connector_refresh_path(theirs) } ].each do |request|
      request.call
      assert_response :not_found
    end
    assert theirs.reload.enabled?
  end
end
