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

  test "creating a workspace waits for the visible form to receive clicks" do
    assert page.evaluate_script("matchMedia('(prefers-reduced-motion: reduce)').matches")
    # This test needs the real transition that the rest of the suite disables.
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "no-preference" } ])
    sign_in_via_ajent
    visit workspaces_path
    wait_for_settled_turbo
    # Stretch the real transition so the form renders while its snapshot still covers it.
    page.execute_script <<~JS
      document.addEventListener('turbo:before-render', ({ detail }) => {
        const style = document.createElement('style')
        style.textContent = '::view-transition-group(*), ::view-transition-old(*), ::view-transition-new(*) { animation-duration: 600ms !important; }'
        detail.newBody.append(style)
      }, { once: true })
    JS
    click_on "New workspace"
    fill_in "Name", with: "Household"
    page.execute_script <<~JS
      document.addEventListener('click', ({ target, isTrusted }) => {
        window.createWorkspaceClick = [target.tagName, document.documentElement.getAttribute('aria-busy'), isTrusted]
      }, { capture: true, once: true })
    JS
    wait_for_settled_turbo
    within(".form__actions") do
      page.driver.browser.action.click(find_button("Create workspace").native).perform
    end
    assert_equal [ "INPUT", nil, true ], page.evaluate_script("window.createWorkspaceClick")
    assert_selector "h1", text: "Household"
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  private
    def reach_rename_and_make
      visit root_path
      wait_for_settled_turbo
      find(".page .agent-group__title a", exact_text: "Yours").click
      assert_selector "h1", text: "Test Operator"
      wait_for_settled_turbo
      click_on "Rename"
      assert_selector "h1", text: "Rename Test Operator"
      fill_in "Name", with: "Home base"
      within(".form__actions") { click_on "Save" }
      assert_selector "h1", text: "Home base"
      wait_for_settled_turbo

      within(".app-header") { click_on "Workspaces" }
      assert_selector "h1", text: "Workspaces"
      within("#workspaces") { assert_text "Home base" }
      wait_for_settled_turbo
      click_on "New workspace"
      fill_in "Name", with: "Household"
      within(".form__actions") { click_on "Create workspace" }
      assert_selector "h1", text: "Household"
      within("#memberships") { assert_text "operator@example.com" }
      wait_for_settled_turbo

      # Now in two, each heads its own group of agents, which leads to its page.
      within(".app-header") { click_on "Workspaces" }
      wait_for_settled_turbo
      click_on "‹ Agents"
      wait_for_settled_turbo
      find(".page .agent-group__title a", text: "Household").click
      assert_selector "h1", text: "Household"
    end
end
