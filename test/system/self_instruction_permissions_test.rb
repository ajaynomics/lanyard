require "application_system_test_case"

class SelfInstructionPermissionsSystemTest < ApplicationSystemTestCase
  LABEL = "Ask before agents change their own instructions"

  test "an install admin can set and reload the choice on all three settings pages" do
    Dir.mktmpdir("instruction-permissions") do |directory|
      with_setting(:app, :instruction_changes_path, Pathname(directory).join("setting")) do
        with_setting(:access, :admins, [ "operator@example.com" ]) do
          sign_in_via_ajent
          user = User.find_by!(oidc_sub: "42") # tenancy-ok: the signed-in person
          agent = user.agents.sole
          workspace = agent.workspace

          page.current_window.resize_to(1280, 900)
          visit workspaces_path
          check_choice "Default (ask)", "Approval required.", "install-default"
          save_choice "Don't ask", "No approval required.", "install-dont-ask"
          save_choice "Ask", "Approval required.", "install-ask"
          save_choice "Don't ask", "No approval required.", "install-dont-ask-again"

          page.current_window.resize_to(390, 844)
          visit workspace_path(workspace)
          check_choice "Inherit from install", "No approval required.", "workspace-inherit"
          save_choice "Ask", "Approval required.", "workspace-ask"
          save_choice "Don't ask", "No approval required.", "workspace-dont-ask"
          save_choice "Ask", "Approval required.", "workspace-ask-again"

          visit agent_permissions_path(agent)
          check_choice "Inherit from workspace", "Approval required.", "agent-inherit"
          save_choice "Don't ask", "No approval required.", "agent-dont-ask"
          save_choice "Ask", "Approval required.", "agent-ask"
          save_choice "Inherit from workspace", "Approval required.", "agent-reset"
          assert_nil agent.reload.own_instruction_approval
        end
      end
    end
  end

  private
    def check_choice(selected, effective, screenshot = nil)
      within("#instruction_change_permissions") do
        assert_select LABEL, selected: selected
        assert_text effective, exact: false
      end
      save_screenshot(Rails.root.join("tmp/screenshots/self-instructions-#{screenshot}.png")) if screenshot
    end

    def save_choice(value, effective, screenshot)
      within("#instruction_change_permissions") do
        select value, from: LABEL
        click_button "Save"
      end
      check_choice value, effective
      wait_for_settled_turbo
      refresh
      check_choice value, effective, screenshot
    end
end
