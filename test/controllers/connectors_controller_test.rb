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
    assert_select "form[action='#{connector_sign_in_path(connector)}'] button", "Sign in again"
    assert_select "#connectors .connector-status[data-status=needs_sign_in]", /Needs sign-in/
  end

  test "a broken connector says why with its fix, and the agent's header counts those it uses" do
    create_mcp_server(@bot, name: "wiki", tools: [ mcp_tool("search") ]).update!(refresh_error: "Could not reach wiki: 503.")
    create_mcp_server(@bot, name: "docs", tools: [ mcp_tool("read") ])
    create_mcp_server(@bot, name: "mail", url: OAUTH_URL, tools: [ mcp_tool("send") ]).update!(refresh_error: "mail needs you to sign in again.", sign_in_needed: true)

    get connectors_path
    assert_select "#connectors .connector-status[data-status=failing]", /Failing.*Could not reach wiki: 503\./m
    assert_select "#connectors .connector-status[data-status=failing] button", "Retry"
    assert_select "#connectors .connector-status[data-status=ok]", /Connected.*1 tool/m
    assert_select "#connectors .connector-status[data-status=needs_sign_in] button", "Sign in again"

    stub_request(:get, "#{SIDECAR}/v1/conversations/#{@agent.durable_id}/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/#{@agent.durable_id}").with(query: hash_including({})).to_return(body: { status: "idle" }.to_json)
    get conversation_path(@agent)
    assert_select "#connectors_button", /Connectors\s*· 2 need you/

    @user.mcp_servers.create!(name: "wiki", enabled: false, conversation: @agent)
    get conversation_path(@agent)
    assert_select "#connectors_button", /Connectors\s*· 1 needs you/
  end

  test "a server that needs no sign-in just lists its tools" do
    stub_mcp_server(tools: [ mcp_tool("search") ])

    assert_enqueued_jobs 1, only: McpServerRefreshJob do
      post connectors_path, params: { connector: { name: "wiki", url: MCP_URL } }
    end
    assert_redirected_to connectors_path
    assert_match(/needs no sign-in/, flash[:notice])
  end

  test "pi's mcp.json entries are accepted as pasted, with literal values" do
    json = { mcpServers: { docs: { url: MCP_URL, headers: { "Authorization" => "Bearer abc", "X-Team" => "one" } },
                           linear: { url: OAUTH_URL, oauth: { clientId: "my-app", clientSecret: "shh", scope: "read" } } } }.to_json
    post connectors_path, params: { connector: { json: json, conversation_id: @agent.id } }

    docs, linear = @agent.mcp_servers.to_a
    assert_equal({ "Authorization" => "Bearer abc", "X-Team" => "one" }, docs.request_headers)
    assert docs.authorized_by_header?
    assert_equal [ "my-app", "read" ], [ linear.oauth_client["client_id"], linear.oauth_scope ]
    assert_not_includes linear.ciphertext_for(:oauth_client), "shh"

    {
      { files: { command: "npx", env: { "TOKEN" => "${TOKEN}" } } } => "files: uses ${…} or !command; paste the value itself.",
      { gh: { url: MCP_URL, headers: { "Authorization" => "Bearer ${GITHUB_TOKEN}" } } } => "gh: uses ${…} or !command; paste the value itself.",
      { gh: { url: MCP_URL, oauth: { clientSecret: "!pass show gh" } } } => "gh: uses ${…} or !command; paste the value itself.",
      { gh: { url: MCP_URL, oauth: { clientRegistration: "cimd" } } } => /client ID metadata document/,
      { old: { url: MCP_URL, type: "sse" } } => "old: uses sse; only http or streamable-http works with a url.",
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

    mine = @user.mcp_servers.create!(name: "files", command: "npx")
    post connector_refresh_path(mine), params: { agent_id: their_agent.id }
    assert_response :not_found
    post connectors_path(agent_id: their_agent.id), params: { connector: { json: { tools: { command: "npx" } }.to_json } }
    assert_response :not_found
    assert_no_enqueued_jobs only: McpServerRefreshJob
  end

  test "a pasted command connector for all agents lists its tools on the computer of the agent it was added from, with no sign-in" do
    @bot.create_computer!(provider: "local", state: "on")
    post connectors_path(agent_id: @agent.id), params: { connector: { json: { files: { command: "npx", args: [ "-y", "files-mcp" ] } }.to_json, conversation_id: "" } }
    connector = @user.mcp_servers.global.sole
    assert_redirected_to connectors_path
    assert_enqueued_with(job: McpServerRefreshJob, args: [ connector, @agent ])

    stub_command_connector(@agent, name: "files", tools: [ mcp_tool("read") ])
    perform_enqueued_jobs
    get conversation_connectors_path(@agent)
    assert_select "#connectors article", /files.*npx -y files-mcp.*Runs on the agent's own computer, with the agent's files and logins, once for each agent that uses it.*read/m

    get connectors_path
    assert_select "#connectors article form[action=?]", connector_refresh_path(connector), count: 0
    post connector_refresh_path(connector), params: { agent_id: @agent.id }
    assert_redirected_to conversation_connectors_path(@agent)
    assert_enqueued_with(job: McpServerRefreshJob, args: [ connector, @agent ])

    @bot.computer.update!(state: "off")
    get conversation_connectors_path(@agent)
    assert_select "#connectors article .flash", /This agent has no computer switched on/
  end
end
