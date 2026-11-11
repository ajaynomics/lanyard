require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# Settings' places, each its own resource in one layout: the sidebar lists
# them, a switch saves and says so, and nothing of another person's opens.
class SettingsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @user.agents.sole
    @conversation = create_conversation(@agent)
  end
  teardown { remove_sidecar_settings }

  test "Settings lists You, Models, Connectors and each agent with its sections" do
    get settings_path
    assert_response :success
    assert_select ".settings[data-index=true]"
    assert_select ".settings-nav__link[href=?]", settings_account_path, text: /You/
    assert_select ".settings-nav__link[href=?]", subscriptions_path, text: "Models"
    assert_select ".settings-nav__link[href=?]", connectors_path, text: "Connectors"
    assert_select ".settings-nav__link[href=?]", agent_path(@agent), text: @agent.name

    get agent_tools_path(@agent)
    assert_select ".settings[data-index=false]"
    assert_select ".settings-nav__section[aria-current=page][href=?]", agent_tools_path(@agent), text: "Tools"
    assert_select "a.settings__up[href=?]", agent_path(@agent), text: @agent.name
  end

  test "You shows who is signed in, and Sign out" do
    get settings_account_path
    assert_select "h1", "You"
    assert_select ".ui-row input#user_name[value=?]", @user.name
    assert_select ".ui-row", text: /Email\s*#{@user.email}/
    assert_select "form[action=?] button", sign_out_path, text: "Sign out"
  end

  test "instructions are saved with Save, and a blank one is refused at the field" do
    get agent_instructions_path(@agent)
    assert_select "form[data-controller=unsaved] textarea#agent_instructions"

    patch agent_instructions_path(@agent), params: { agent: { instructions: "Be brief." } }
    assert_redirected_to agent_instructions_path(@agent)
    assert_equal "Be brief.", @agent.reload.instructions

    patch agent_instructions_path(@agent), params: { agent: { instructions: " " } }
    assert_response :unprocessable_entity
    assert_select "textarea#agent_instructions[aria-invalid=true]"
  end

  test "a connector's tool goes off for every agent on its page, and for one agent in that agent's Tools" do
    wiki = create_mcp_server(@agent, name: "wiki", tools: [ mcp_tool("search"), mcp_tool("edit") ])

    patch connector_tool_path(wiki, "search"), params: { on: "0" }, headers: { "Referer" => connector_url(wiki) }
    assert_redirected_to connector_path(wiki)
    assert_equal true, flash[:saved]
    assert_equal [ "search" ], wiki.reload.disabled_tools
    patch connector_tool_path(wiki, "nothing"), params: { on: "0" }
    assert_response :not_found

    patch agent_tool_path(@agent, "mcp__wiki__edit"), params: { on: "0" }
    assert_redirected_to agent_tools_path(@agent)
    assert_equal [ "mcp__wiki__edit" ], @agent.reload.disabled_tools
    get agent_tools_path(@agent)
    assert_select ".ui-row", text: /search.*Off for every agent/m
    assert_select "#tool_mcp__wiki__search[disabled]"
    assert_select ".ui-row", text: /edit.*Off for #{@agent.name} only/m
    assert_select "#tool_meter", /of 64 tools/

    patch agent_tool_path(@agent, "mcp__wiki__edit"), params: { on: "1" }
    assert_empty @agent.reload.disabled_tools
    patch agent_tool_path(@agent, "mcp__elsewhere__edit"), params: { on: "0" }
    assert_response :not_found
  end

  test "a signed-out connector's tools are greyed in the agent's Tools and on its page, with the Sign in that brings them back" do
    mail = create_mcp_server(@agent, name: "mail", tools: [ mcp_tool("send") ])
    count = @agent.tool_count
    mail.sign_out

    get agent_tools_path(@agent)
    assert_select ".ui-group__title h2", /mail\s*Needs sign-in/
    assert_select ".ui-group__title form[action=?] button", connector_sign_in_path(mail), "Sign in again"
    assert_select ".ui-row[data-unavailable]", /send.*Needs sign-in/m
    assert_select "#tool_mcp__mail__send[disabled]"
    assert_select "#tool_meter", /#{count - 1} of 64 tools/

    get connector_path(mail)
    assert_select ".settings__problem form[action=?] button", connector_sign_in_path(mail), "Sign in again"
    assert_select ".ui-row[data-unavailable]", /send.*Needs sign-in/m
    assert_select "#connector_tool_send[disabled]"
  end

  test "another person's agent's settings and connectors are not found" do
    mallory = create_user(name: "Mallory").agents.sole
    theirs = create_mcp_server(mallory, tools: [ mcp_tool("search") ])

    [ agent_instructions_path(mallory), agent_tools_path(mallory), agent_permissions_path(mallory), agent_channels_path(mallory),
      agent_computer_path(mallory), agent_routines_path(mallory), connector_path(theirs) ].each do |path|
      get path
      assert_response :not_found, path
    end
    patch connector_tool_path(theirs, "search"), params: { on: "0" }
    assert_response :not_found
    patch agent_tool_path(mallory, "current_time"), params: { on: "0" }
    assert_response :not_found
    assert_empty theirs.reload.disabled_tools
  end
end
