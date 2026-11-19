require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Tool::ChangeYourselfTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
  end

  test "every agent has it, and it asks the person first" do
    assert_includes @agent.conversation.definition[:lookup].pluck(:name), "change_yourself", "looked up: not in Tool::Catalog::CORE"
    assert_equal :approval, @agent.conversation.tool("change_yourself").asks

    assert_equal "waiting", receive("change_yourself", { "instructions" => "Grow tomatoes." }, call_id: "c1")[:status]
    assert_not_equal "Grow tomatoes.", @agent.reload.instructions
  end

  test "once allowed it replaces the agent's instructions, keeping a revision; its name is not its to change" do
    assert_difference -> { @agent.revisions.count } do
      assert_equal({ instructions: "saved" }, approved("c1", "instructions" => "Grow tomatoes.")[:result])
    end
    assert_equal [ "Assistant", "Grow tomatoes." ], @agent.reload.values_at(:name, :instructions)
    assert_equal %w[ instructions scope note_to_approver ], Tool::ChangeYourself.schema["properties"].keys
  end

  # It is looked up, so the agent reaches it through use_tool (#253): it must
  # read its own arguments there, or the workspace scope would lose its
  # approver and ask as an ordinary change to the agent itself.
  test "through use_tool, the workspace scope still decides who may allow it" do
    assert_equal "waiting", used("c1", "instructions" => "Share the shed.", "scope" => "workspace")[:status]
    invocation = @conversation.invocations.sole

    assert_equal @agent.workspace.owner, invocation.approver
    assert_equal "Change #{@agent.workspace}'s shared instructions?", invocation.approval_title
    assert_match "Only #{@agent.workspace.owner}, its owner, can allow it.", invocation.approval_note
  end

  private
    def receive(tool, arguments, call_id:)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    # The call as the sidecar replays it after the person allows it.
    def approved(call_id, arguments)
      receive("change_yourself", arguments, call_id: call_id)
      @conversation.invocations.find_by!(call_id: call_id).approve!(by: @alice)
      receive("change_yourself", arguments, call_id: call_id)
    end

    # The same call through use_tool, as find_tools offers it.
    def used(call_id, arguments)
      receive("use_tool", { "name" => "change_yourself", "arguments" => arguments }, call_id: call_id)
    end
end
