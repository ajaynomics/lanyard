require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Workspace::AgentSetupFirstTurnTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @owner = create_user(name: "Taylor")
    @operator = create_user(name: "Morgan")
    @team = Workspace.make(name: "Team", owner: @owner)
    @team.memberships.create!(user: @operator, role: "member")
    @manager = @owner.start_agent("Lead", workspace: @team)
    @setup = @team.agent_setups.build(approved_by: @owner, operator: @operator, manager_id: @manager.id,
      request_id: SecureRandom.uuid, name: "Research desk", instructions: "Summarize evidence.", authorization: "Use the approved reporting line.").record!
    @report = @setup.execute!(by: @operator)
    @thread = @report.conversation
  end

  test "one approved first turn names the actual local manager, not a person or caller supplied sender" do
    turn = @setup.prepare_first_turn!("Please summarize the figures.", by: @manager)
    payload = JSON.parse(turn.payload)
    assert_equal({ "sender" => "Lead" }, payload.fetch("author"))
    assert_equal "followUp", payload.fetch("whenBusy")
    assert_not payload.key?("fromPerson")
    assert_match(/\[Manager handoff from Lead\./, payload.fetch("content"))
    assert_includes payload.fetch("content"), Conversation::UNTRUSTED
    assert_empty @report.concourse_agents
    assert_nil @thread.reload.durable_id

    assert_equal turn, @setup.prepare_first_turn!("Please summarize the figures.", by: @manager)
    assert_raises(Conversation::Submission::Conflict) { @setup.prepare_first_turn!("Different message", by: @manager) }
    assert_equal 1, @thread.submissions.count
  end

  test "a different manager, changed reporting line or revoked approval cannot prepare a turn" do
    stranger = @owner.start_agent("Other lead", workspace: @owner.personal_workspace)
    assert_raises(ActiveRecord::RecordNotFound) { @setup.prepare_first_turn!("Outside the workspace", by: stranger) }
    @report.update!(parent_id: nil)
    assert_raises(ActiveRecord::RecordNotFound) { @setup.prepare_first_turn!("Not a report", by: @manager) }
    @report.update!(parent_id: @manager.id)
    @setup.revoke!(by: @owner)
    assert_raises(ActiveRecord::RecordNotFound) { @setup.prepare_first_turn!("Authorization revoked", by: @manager) }
    assert_empty @thread.submissions
    assert_empty @report.concourse_agents
  end

  test "a moved report or a thread already used is not a first turn" do
    @thread.update!(durable_id: "42")
    assert_raises(Workspace::AgentSetup::Conflict) { @setup.prepare_first_turn!("Already active", by: @manager) }
    assert_empty @thread.submissions
    assert @report.move_to(@owner.personal_workspace, by: @owner)
    assert_raises(ActiveRecord::RecordNotFound) { @setup.prepare_first_turn!("Old workspace", by: @manager) }
    assert_empty @thread.submissions
  end
end
