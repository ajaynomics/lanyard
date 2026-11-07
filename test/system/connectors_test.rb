require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/fake_oauth_mcp"
require_relative "../test_helpers/mcp_test_helper"

# The MCP sign-in in a real browser: a service's MCP server and authorization
# server (FakeOauthMcp) run on this machine, the browser goes to its sign-in
# page and back, and the agent then has its tools. Once for a connector every
# agent gets, once for one agent's own.
class ConnectorsTest < ApplicationSystemTestCase
  include AgentTestHelper
  include ActiveJob::TestHelper
  include McpTestHelper

  setup do
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @agent = create_conversation(@user.bots.sole, durable_id: "1")
    @other = create_conversation(@user.bots.sole, durable_id: "2")
    @service = Capybara::Server.new(FakeOauthMcp.new).boot
    # The sign-in comes back to the app the browser is using.
    @app_settings = Rails.application.config.x.app
    Rails.application.config.x.app = @app_settings.merge(url: Capybara.current_session.server.base_url)
  end
  teardown do
    Rails.application.config.x.app = @app_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "a connector for all agents: sign in, come back signed in, and every agent has its tools" do
    visit connectors_path
    add_connector "shared"

    assert_text "Signed in to shared"
    perform_enqueued_jobs
    visit connectors_path
    within("#connectors article", text: "shared") do
      assert_text "Signed in"
      assert_button "Sign out"
      assert_text "echo"
    end

    assert @agent.tool("mcp__shared__echo")
    assert @other.tool("mcp__shared__echo")
    assert_equal({ "content" => [ { "type" => "text", "text" => "echo: hi" } ] }, @user.mcp_servers.sole.call_tool("echo", { "text" => "hi" }))
  end

  test "a connector for one agent only: added from its page, signed in, and only that agent has its tools" do
    visit conversation_connectors_path(@agent)
    add_connector "mine"

    assert_text "Signed in to mine"
    assert_current_path conversation_connectors_path(@agent)
    perform_enqueued_jobs
    visit conversation_connectors_path(@agent)
    within("#connectors article", text: "mine") { assert_text "echo" }

    assert @agent.tool("mcp__mine__echo")
    assert_nil @other.tool("mcp__mine__echo")
    assert_equal({ "content" => [ { "type" => "text", "text" => "echo: there" } ] }, @agent.mcp_servers.sole.call_tool("echo", { "text" => "there" }))
  end

  test "a pasted command connector for one agent runs on its computer, and its tools show up" do
    install_sidecar_settings
    @user.bots.sole.create_computer!(provider: "local", state: "on")
    stub_command_connector(@agent, name: "files", tools: [ mcp_tool("read_file", description: "Reads a file in the agent's folder.") ])

    visit conversation_connectors_path(@agent)
    within "#pasted_connector" do
      fill_in "Entries from pi's mcp.json", with: { mcpServers: { files: { command: "npx", args: [ "-y", "files-mcp" ] } } }.to_json
      choose "Only this agent"
      click_on "Add from pi"
    end

    assert_text "Added files"
    perform_enqueued_jobs
    visit conversation_connectors_path(@agent)
    within("#connectors article", text: "files") do
      assert_text "npx -y files-mcp"
      assert_text "Runs on the agent's own computer, with the agent's files and logins."
      assert_text "read_file"
    end
    assert @agent.tool("mcp__files__read_file")
    assert_nil @other.tool("mcp__files__read_file")
  ensure
    remove_sidecar_settings
  end

  private
    def add_connector(name)
      within "#new_connector" do
        fill_in "Name", with: name
        fill_in "Web address", with: "#{@service.base_url}/mcp"
        click_on "Add connector"
      end
    end
end
