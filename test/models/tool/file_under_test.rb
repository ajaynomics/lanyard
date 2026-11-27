require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# file_under (#277): the agent names the client file or matter its work is
# about, so what the run uses is reported by file. Bookkeeping: nobody is asked.
class Tool::FileUnderTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    assert @agent.switch_tool("file_under", true), @agent.errors.full_messages.to_sentence
    @conversation = create_conversation(@agent)
  end

  test "it files the thread under the label, stripped and cut to 100 characters, and a blank label clears it" do
    assert_equal({ filedUnder: "EXAMPLE-FILE-A" }, use({ "label" => "  EXAMPLE-FILE-A \n" }, call_id: "toolu_1"))
    assert_equal "EXAMPLE-FILE-A", @conversation.reload.filed_under

    use({ "label" => "x" * 150 }, call_id: "toolu_2")
    assert_equal "x" * 100, @conversation.reload.filed_under

    assert_equal({ filedUnder: nil }, use({ "label" => "   " }, call_id: "toolu_3"))
    assert_nil @conversation.reload.filed_under
    assert_equal 3, @conversation.invocations.succeeded.count, "none waited for a person"
  end

  test "it asks nobody, reaches nobody, and is picked one by one and looked up" do
    tool = Tool::Catalog.find("file_under")
    assert_nil tool.asks
    assert_not tool.reaches_others?
    assert_not Tool::Catalog.core?(tool)
    starters = Dir[Rails.root.join("config/agents/*/agent.yml")].flat_map { YAML.safe_load_file(it).fetch("tools") }
    assert_not_includes starters, "file_under"
    assert_not_includes @alice.start_agent("Fresh").tool_names, "file_under"
    assert_not @conversation.declares?("file_under"), "looked up, so it costs no declared tool"
    assert @conversation.tool("file_under")
    assert_match "before doing the work", tool.description
  end

  private
    def use(arguments, call_id:)
      payload = invocation_payload(@conversation, tool: "file_under", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "file_under",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys.fetch(:result)
    end
end
