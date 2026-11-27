require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/concourse_test_helper"

class PeerTaskTest < ActiveSupport::TestCase
  include AgentTestHelper, ConcourseTestHelper

  setup do
    @agent = create_user.agents.sole
    @primary = create_concourse_agent(@agent)
    @conversation = @agent.conversation
  end

  test "another agent's tagged channel is refused even in the same workspace" do
    other = @agent.workspace.agents.create!(user: @agent.user, name: "Other", instructions: "Help.", model: Agent.models.first)
    task = link_task(create_concourse_agent(other)).reload

    assert_nil task.channel
  end

  test "a valid tag selects the conversation agent's exact channel" do
    second = create_second_network(@agent)

    assert_equal second, link_task(second).reload.channel
  end

  test "an untagged legacy task uses its own agent's first channel" do
    assert_equal @primary, link_task(nil).reload.channel
  end

  private
    def link_task(channel)
      @conversation.peer_tasks.create!(concourse_agent: channel, task_id: "example-task", direction: "inbound",
        peer: "example/helper", state: "TASK_STATE_SUBMITTED")
    end
end
