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
    assert_includes @agent.definition[:tools].pluck(:name), "change_yourself"
    assert_equal :approval, @agent.tool("change_yourself").asks

    assert_equal "waiting", receive("change_yourself", { "name" => "Gardener" }, call_id: "c1")[:status]
    assert_equal "Assistant", @agent.reload.name
  end

  test "once allowed it renames the agent, replaces its instructions, or both, keeping a revision" do
    assert_equal({ name: "Gardener", instructions: "saved" }, approved("c1", "name" => "Gardener")[:result])
    assert_equal "Gardener", @agent.reload.name

    assert_difference -> { @agent.revisions.count } do
      approved("c2", "instructions" => "Grow tomatoes.")
    end
    assert_equal [ "Gardener", "Grow tomatoes." ], @agent.reload.values_at(:name, :instructions)

    approved("c3", "name" => "Cook", "instructions" => "Cook them.")
    assert_equal [ "Cook", "Cook them." ], @agent.reload.values_at(:name, :instructions)
  end

  test "with neither a name nor instructions it refuses and changes nothing" do
    outcome = approved("c1", {})

    assert outcome[:isError]
    assert_equal "Send a new name, new instructions, or both.", outcome[:result][:error]
    assert_equal "Assistant", @agent.reload.name
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
