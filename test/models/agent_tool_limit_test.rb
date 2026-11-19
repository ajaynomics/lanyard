require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The sidecar refuses a definition of more than Agent::TOOL_LIMIT tools, and
# with it every message. A connector's save checks the count, but a deploy
# that adds tools does not save one: past the limit, the last core
# connectors' tools are looked up instead.
class AgentToolLimitTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    # find_tools and use_tool among them: they reach its rarer built-ins already.
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
    looked_up = tools.last.schema.dig("properties", "name", "enum").grep(/\Amcp__/)
    assert_equal 1, looked_up.size, "only the one over"
    assert looked_up.all? { it.start_with?("mcp__zeta__") }, "the last connector's go first"
    assert_includes looked_up, "mcp__zeta__tool_#{Agent::TOOL_LIMIT - @own - 10}", "its last tool among them"
  end

  test "at the limit nothing moves, and a connector looked up shares the two lookup tools" do
    connector("alpha", Agent::TOOL_LIMIT - @own)
    assert_equal Agent::TOOL_LIMIT, @agent.reload.conversation.tools.size
    assert_empty @agent.conversation.tool("use_tool").tools.map(&:tool_name).grep(/\Amcp__/)

    connector("beta", 3, core: false)
    tools = @agent.reload.conversation.tools
    assert_equal Agent::TOOL_LIMIT, tools.size
    assert_equal 3, tools.last.schema.dig("properties", "name", "enum").grep(/\Amcp__/).size, "beta's three, none of alpha's"
  end

  test "the agent's settings still refuse to make core a connector that takes it past, and its meter shows what it wants" do
    connector("alpha", Agent::TOOL_LIMIT + 1 - @own)
    assert_equal Agent::TOOL_LIMIT + 1, @agent.tool_count

    added = @agent.user.mcp_servers.create!(name: "omega", url: "https://omega.example.com/mcp", tools: listing("omega", 1))
    assert_not @agent.core?(added), "a new connector is looked up"
    core = Agent::CoreConnector.new(agent: @agent, mcp_server: added)
    assert_not core.valid?
    assert_match "an agent can have #{Agent::TOOL_LIMIT}", core.errors.full_messages.to_sentence
  end

  # campfire_history reaches every bot without its tool_names changing: a deploy
  # adds it, so a bot at the limit before is one past it after.
  test "a Campfire bot at the limit gains campfire_history on a deploy, and a connector's tool is looked up instead" do
    @agent.create_campfire_bot!(bot_key: "4-abc123")
    with_setting(:campfire, :url, "http://example-campfire") do
      own = @agent.reload.tools([]).size
      assert_empty Tool::Catalog::CAMPFIRE.map(&:tool_name) - @agent.own_tools.map(&:tool_name), "every Campfire tool, with no tool_names change"
      connector("alpha", Agent::TOOL_LIMIT + 1 - own)

      tools = @agent.reload.conversation.tools
      names = tools.map(&:tool_name)
      assert_equal Agent::TOOL_LIMIT, tools.size
      assert_includes names, "campfire_history"
      assert_equal %w[ find_tools use_tool ], names.last(2)
      assert_equal 1, tools.last.schema.dig("properties", "name", "enum").grep(/\Amcp__/).size, "one of alpha's looked up, for 65 wanted"
    end
  end

  private
    # As a deploy leaves it: listed without the save's check.
    # Core for the agent unless `core: false`, as the migration left one that was loaded.
    def connector(name, count, core: true)
      @agent.workspace.mcp_servers.new(user: @agent.user, name: name, url: "https://#{name}.example.com/mcp", tools: listing(name, count),
        refreshed_at: Time.current).tap do
        it.save!(validate: false)
        @agent.core_connectors.new(mcp_server: it).save!(validate: false) if core
      end
    end

    def listing(name, count)
      Array.new(count) { { "name" => "tool_#{it}", "description" => "Tool #{it} of #{name}.", "input_schema" => { "type" => "object" },
        "annotations" => { "readOnlyHint" => true } } }
    end
end
