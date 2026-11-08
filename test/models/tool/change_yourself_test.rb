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
    assert_includes @agent.conversation.definition[:tools].pluck(:name), "change_yourself"
    assert_equal :approval, @agent.conversation.tool("change_yourself").asks

    assert_equal "waiting", receive("change_yourself", { "instructions" => "Grow tomatoes." }, call_id: "c1")[:status]
    assert_not_equal "Grow tomatoes.", @agent.reload.instructions
  end

  test "once allowed it replaces the agent's instructions, keeping a revision; its name is not its to change" do
    assert_difference -> { @agent.revisions.count } do
      assert_equal({ instructions: "saved" }, approved("c1", "instructions" => "Grow tomatoes.")[:result])
    end
    assert_equal [ "Assistant", "Grow tomatoes." ], @agent.reload.values_at(:name, :instructions)
    assert_equal %w[ instructions ], Tool::ChangeYourself.schema["properties"].keys
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
end
