require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The sidecar refuses a definition of more than Agent::TOOL_LIMIT tools, and
# with it every message. A connector's save checks the count, but a deploy
# that adds tools does not save one: past the limit, the last loaded
# connectors' tools are looked up instead.
class AgentToolLimitTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    @own = @agent.tools([]).size
  end

  test "past the limit the last connector's last tools are looked up, and no more than the limit are declared" do
    connector("alpha", 10)
    connector("zeta", Agent::TOOL_LIMIT + 1 - @own - 10)
    assert_equal Agent::TOOL_LIMIT + 1, @agent.wanted_tool_count(@conversation.connectors), "65 wanted"

    tools = @agent.reload.conversation.tools
    names = tools.map(&:tool_name)
    assert_equal Agent::TOOL_LIMIT, tools.size
    assert_equal %w[ find_tools use_tool ], names.last(2)
    assert_equal (0...10).map { "mcp__alpha__tool_#{it}" }, names.grep(/\Amcp__alpha__/), "the first connector keeps every tool"
    looked_up = tools.last.schema.dig("properties", "name", "enum")
    assert_equal 3, looked_up.size
    assert looked_up.all? { it.start_with?("mcp__zeta__") }, "the last connector's go first"
    assert_includes looked_up, "mcp__zeta__tool_#{Agent::TOOL_LIMIT - @own - 10}", "its last tool among them"
  end

  test "at the limit nothing moves, and a connector already looked up shares the two lookup tools" do
    connector("alpha", Agent::TOOL_LIMIT - @own)
    assert_equal Agent::TOOL_LIMIT, @agent.reload.conversation.tools.size
    assert_empty @agent.conversation.tools.map(&:tool_name) & %w[ find_tools use_tool ]

    connector("beta", 3, loaded: false)
    tools = @agent.reload.conversation.tools
    assert_equal Agent::TOOL_LIMIT, tools.size
    assert_equal 5, tools.last.schema.dig("properties", "name", "enum").size, "two of alpha's moved beside beta's three"
  end

  test "the agent's settings still refuse a connector that takes it past, and its meter shows what it wants" do
    connector("alpha", Agent::TOOL_LIMIT + 1 - @own)
    assert_equal Agent::TOOL_LIMIT + 1, @agent.tool_count

    added = @agent.user.mcp_servers.build(name: "omega", url: "https://omega.example.com/mcp", tools: listing("omega", 1))
    assert_not added.valid?
    assert_match "can have #{Agent::TOOL_LIMIT} in all", added.errors.full_messages.to_sentence
  end

  private
    # As a deploy leaves it: listed without the save's check.
    def connector(name, count, loaded: true)
      @agent.user.mcp_servers.new(name: name, url: "https://#{name}.example.com/mcp", tools: listing(name, count), loaded: loaded,
        refreshed_at: Time.current).tap { it.save!(validate: false) }
    end

    def listing(name, count)
      Array.new(count) { { "name" => "tool_#{it}", "description" => "Tool #{it} of #{name}.", "input_schema" => { "type" => "object" },
        "annotations" => { "readOnlyHint" => true } } }
    end
end
