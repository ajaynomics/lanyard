require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# Workspaces › Overview on screen: reached from the agents list, a block for each
# of Bob's workspaces, and a stuck card's link opening it in its workspace.
class WorkspacesOverviewTest < ApplicationSystemTestCase
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
    @planner = @alice.start_agent("Planner", workspace: @household)
    @planner.conversation.update!(durable_id: "41", request_id: "r-41")
    @card = @planner.conversation.invocations.create!(task_id: "7", call_id: "toolu_q", tool_name: "ask_person",
      arguments: { "question" => "Which evening for dinner?" }, digest: "q", state: "awaiting_person", expires_at: 1.day.from_now, created_at: 2.hours.ago)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "from the agents list, every workspace's block; a stuck card opens in its own workspace" do
    skip "Quarantined: flaky, never-settles class: the page stayed html[aria-busy] past the wait before Overview's click (docs/flaky-tests.md)"
    visit root_path
    within("#group_workspace_#{@household.id} .agent-group__title") { assert_text "1 waiting" }
    within(".agent-groups__more") { click_on "Overview" }

    assert_selector "h1", text: "Overview"
    assert_equal [ "Test Operator · Yours", "Household · 2 people" ], all(".workspace-health h2").map { it.text.squish }
    within("#workspace_health_#{@bob.personal_workspace.id}") { assert_text "Nothing is waiting" }
    within("#workspace_health_#{@household.id}") do
      assert_text "Waiting for you · 1"
      assert_selector ".ui-row", text: /Which evening for dinner\?.*Stuck/m
      click_on "Which evening for dinner?"
    end

    assert_current_path approval_path(@card)
    assert_text "Which evening for dinner?"
    # Opened from Turbo's prefetch, the session's workspace may be another; the page's own link names its workspace.
    assert_equal new_agent_path(workspace_id: @household.id), find("body")["data-shortcuts-new-agent-value"]
  end
end
