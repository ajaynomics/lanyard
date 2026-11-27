require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class InstructionRevisionTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @workspace = @agent.workspace
    @conversation = create_conversation(@agent)
    @invocation = @conversation.invocations.create!(task_id: "t", call_id: "c1", tool_name: "change_yourself", digest: "d")
    @approval = @invocation.create_approval!(decision: "approve", decided_by: @maya)
  end

  test "an agent's change records the approval, its call and the workspace it was given in" do
    @agent.change_instructions("Be brief.", approval: @approval, invocation: @invocation)
    approved = @agent.revisions.last
    assert_equal [ "Be brief.", @approval, @invocation, @workspace ], [ approved.instructions, approved.approval, approved.invocation, approved.instruction_workspace ]

    @agent.update!(instructions: "Be plain.")
    assert_equal [ nil, nil ], @agent.revisions.last.values_at(:approval_id, :invocation_id), "an edit by hand records none"
  end

  test "a workspace's change records the approval" do
    @workspace.change_instructions("Share the shed.", by: @maya, proposed_by: @agent, approval: @approval)
    approved = @workspace.revisions.first
    assert_equal [ @approval, @agent ], [ approved.approval, approved.proposed_by_agent ]
  end
end
