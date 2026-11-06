require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/mcp_test_helper"

class Bots::McpServersControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  setup do
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person adds a server, and its tools are listed away from the request" do
    assert_enqueued_jobs 1, only: McpServerRefreshJob do
      post bot_mcp_servers_path(@bot), params: { mcp_server: { name: "wiki", url: MCP_URL, token: "secret-token-1" } }
    end
    assert_redirected_to bot_path(@bot, anchor: "mcp_servers")
    server = @bot.mcp_servers.sole
    assert_equal "secret-token-1", server.token

    follow_redirect!
    assert_select "#mcp_servers", /Listing its tools/
    assert_select "#mcp_servers", text: /secret-token-1/, count: 0

    stub_mcp_server(tools: [ mcp_tool("search", description: "Searches the wiki.") ])
    perform_enqueued_jobs
    get bot_path(@bot)
    assert_select "#mcp_servers .list__item", /search.*Searches the wiki.*Asks you first/m
  end

  test "a server that does not validate is not added" do
    post bot_mcp_servers_path(@bot), params: { mcp_server: { name: "Wiki!", url: "http://mcp.example.test" } }

    assert_redirected_to bot_path(@bot, anchor: "mcp_servers")
    assert_empty @bot.mcp_servers
    assert_match(/Name must start with a letter/, flash[:alert])
    assert_match(/Url must start with https/, flash[:alert])
  end

  test "the person refreshes and removes a server" do
    server = create_mcp_server(@bot, tools: [ mcp_tool("search") ])

    assert_enqueued_with(job: McpServerRefreshJob, args: [ server ]) { post bot_mcp_server_refresh_path(@bot, server) }
    assert_redirected_to bot_path(@bot, anchor: "mcp_servers")

    delete bot_mcp_server_path(@bot, server)
    assert_redirected_to bot_path(@bot, anchor: "mcp_servers")
    assert_empty @bot.mcp_servers.reload
    assert_nil @bot.reload.tool("mcp__wiki__search")
  end

  test "someone else's bot and servers are not found" do
    other = create_user(name: "Other").bots.sole
    server = create_mcp_server(other)

    post bot_mcp_servers_path(other), params: { mcp_server: { name: "wiki", url: MCP_URL } }
    assert_response :not_found
    post bot_mcp_server_refresh_path(@bot, server)
    assert_response :not_found
    delete bot_mcp_server_path(@bot, server)
    assert_response :not_found
    assert other.mcp_servers.exists?
  end
end
