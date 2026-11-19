require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# An agent's workspace on screen: New agent makes it in the workspace the
# person chooses, from its group in the agents list, and its owner moves it to
# another of theirs. Clicks only,
# from the agents list. Bob is the person the browser signs in as; Alice owns
# the shared workspace he is in.
class AgentWorkspacesTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+(\?.*)?\z}).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    @alice = create_user(name: "Alice", email: "member@example.com")
    sign_in_via_ajent
    @bob = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @bob.start_agent("Bob's own") if @bob.agents.none?
    @household = Workspace.create!(name: "Household")
    @household.memberships.create!(user: @alice, role: "owner")
    @household.memberships.create!(user: @bob, role: "member")
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "New agent makes the agent in the workspace he chooses, from its group or on the form" do
    visit root_path
    within("#group_workspace_#{@household.id}") { click_on "Make your first" }
    assert_select "Workspace", selected: "Household"
    fill_in "Name", with: "Pantry"
    click_on "Start"

    assert_selector "#composer"
    pantry = @bob.agents.find_by!(name: "Pantry")
    assert_equal @household, pantry.workspace
    assert_not_includes @bob.personal_workspace.agents, pantry

    visit new_agent_path
    select "Test Operator", from: "Workspace"
    fill_in "Name", with: "Ledger"
    click_on "Start"
    assert_selector "#composer"
    assert_equal @bob.personal_workspace, @bob.agents.find_by!(name: "Ledger").workspace
  end

  test "Bob moves his own agent into Household, where he then works and it is listed; there only Alice could move it again" do
    own = @bob.personal_workspace.agents.order(:id).first
    visit root_path
    click_on "Settings"
    within(".settings-nav", text: own.name) { click_on own.name }
    within("#agent_workspace") do
      assert_text "Test Operator"
      click_on "Move"
    end
    assert_selector "h1", text: "Move #{own.name}"
    choose "Household"
    click_on "Move #{own.name}"

    assert_text "Moved #{own.name} to Household."
    within("#agent_workspace") do
      assert_text "Household"
      assert_no_link "Move"
      assert_text "Only Alice, who owns Household, can move it."
    end
    assert_equal @household, own.reload.workspace

    # Out of Settings, to its thread, in Household's group, and no longer in his own.
    click_on "‹ Agents"
    assert_selector ".chat-sidebar #group_workspace_#{@household.id} .conversation-row", text: own.name
    assert_no_selector ".chat-sidebar #group_workspace_#{@bob.personal_workspace.id} .conversation-row", text: own.name
  end
end
