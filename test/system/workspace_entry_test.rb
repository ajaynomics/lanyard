require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# From the agents list, by clicking alone, a person reaches their workspace's
# page, renames their own, makes a shared one and manages it: with each
# person their own, and in an install that serves one person, which refuses
# to invite.
class WorkspaceEntryTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+(\?.*)?\z}).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "each person their own: the name above the agents leads to its page and back; Settings to a new shared one, managed" do
    sign_in_via_ajent
    reach_rename_and_make
    assert_selector "#invitations_title", text: "Invited"
    assert_field "Invite by email"
  end

  test "an install that serves one person: the same, and its page says inviting needs single-owner mode off" do
    with_setting(:access, :owner, "operator@example.com") do
      sign_in_via_ajent
      reach_rename_and_make
      assert_selector "#invitations_refused", text: "Inviting people needs single-owner mode off."
      assert_no_field "Invite by email"
    end
  end

  private
    # A Turbo visit still under way covers the page, so a click on what it shows would miss.
    def settled = assert_no_selector("html[aria-busy]", visible: :all)

    def reach_rename_and_make
      visit root_path
      settled
      find(".page .agent-group__title a", text: "Test Operator").click
      assert_selector "h1", text: "Test Operator"
      settled
      click_on "Rename"
      assert_selector "h1", text: "Rename Test Operator"
      fill_in "Name", with: "Home base"
      click_on "Save"
      assert_selector "h1", text: "Home base"
      settled

      within(".app-header") { click_on "Workspaces" }
      assert_selector "h1", text: "Workspaces"
      within("#workspaces") { assert_text "Home base" }
      settled
      click_on "New workspace"
      fill_in "Name", with: "Household"
      click_on "Create workspace"
      assert_selector "h1", text: "Household"
      within("#memberships") { assert_text "operator@example.com" }
      settled

      # Now in two, each heads its own group of agents, which leads to its page.
      within(".app-header") { click_on "Workspaces" }
      settled
      click_on "‹ Agents"
      settled
      find(".page .agent-group__title a", text: "Household").click
      assert_selector "h1", text: "Household"
    end
end
