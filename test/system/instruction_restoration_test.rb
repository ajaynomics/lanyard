require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

class InstructionRestorationSystemTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup { install_sidecar_settings }
  teardown { remove_sidecar_settings }

  test "a revision approved over a week ago, its call since pruned, is listed and restored" do
    sign_in_via_ajent
    user = User.find_by!(oidc_sub: "42") # tenancy-ok: the signed-in person
    agent = user.agents.sole
    agent.update!(instructions: "Keep notes in plain English.\n\nWrite them in clear English.")
    conversation = create_conversation(agent)
    arguments = { "edits" => [ { "find" => "Write them in clear English.", "replace" => "Answer in Spanish." } ] }
    payload = invocation_payload(conversation, tool: "change_yourself", arguments: arguments)
    receive = -> { Invocation.receive(conversation, task_id: payload[:taskId], call_id: "toolu_1", tool: "change_yourself", arguments: arguments, digest: payload[:digest]) }
    assert_equal "waiting", receive.call[:status]
    conversation.invocations.sole.approve!(by: user)
    receive.call
    source = agent.revisions.reorder(id: :desc).first!
    agent.update!(instructions: "Keep notes in plain English.")

    travel Invocation::RESULTS_KEPT + 1.day
    Invocation.prune_results
    sign_in_via_ajent

    visit agent_instruction_revisions_path(agent)
    click_link "Review revision #{source.id}"
    assert_selector "#instruction_restore_diff", text: "Answer in Spanish."
    save_screenshot(Rails.root.join("tmp/screenshots/instruction-restore-after-prune.png"))
    click_button "Restore as new revision"

    assert_text "Restored as a new revision."
    assert_field "agent_instructions", with: "Keep notes in plain English.\n\nAnswer in Spanish."
    assert_equal "Keep notes in plain English.\n\nAnswer in Spanish.", agent.reload.instructions
  end
end
