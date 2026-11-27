require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Save checks use the same budget as the declaration, leaving space for
# tool search. A deploy that adds tools does not save a connector: past the
# budget, the last core connectors' tools are looked up instead.
class AgentToolLimitTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    # The sidecar's own count as the model sees them, beside the declared, and
    # its tool_search among them, as its rarer built-ins are looked up already.
    @sidecar = @agent.sidecar_tool_names.size + @agent.lookup_sidecar_tool_names.size
    @own = @agent.tool_count
  end

  test "past the limit the last connector's last tools are looked up, and no more than the limit are declared" do
    connector("alpha", 10)
    connector("zeta", Agent::TOOL_LIMIT + 1 - @own - 10)
    assert_equal Agent::TOOL_LIMIT + 1, @agent.wanted_tool_count(@conversation.connectors)

    tools = @agent.reload.conversation.tools
    names = tools.map(&:tool_name)
    assert_equal Agent::TOOL_LIMIT - @sidecar, tools.size
    assert_equal (0...10).map { "mcp__alpha__tool_#{it}" }, names.grep(/\Amcp__alpha__/), "the first connector keeps every tool"
    looked_up = @agent.conversation.lookup_tools.map(&:tool_name).grep(/\Amcp__/)
    assert_equal 1, looked_up.size, "only the one over"
    assert looked_up.all? { it.start_with?("mcp__zeta__") }, "the last connector's go first"
    assert_includes looked_up, "mcp__zeta__tool_#{Agent::TOOL_LIMIT - @own - 10}", "its last tool among them"
  end

  test "at the limit nothing moves, and a connector looked up adds nothing declared" do
    connector("alpha", Agent::TOOL_LIMIT - @own)
    assert_equal Agent::TOOL_LIMIT - @sidecar, @agent.reload.conversation.tools.size
    assert_empty @agent.conversation.lookup_tools.map(&:tool_name).grep(/\Amcp__/)

    connector("beta", 3, core: false)
    assert_equal Agent::TOOL_LIMIT - @sidecar, @agent.reload.conversation.tools.size
    assert_equal 3, @agent.conversation.lookup_tools.map(&:tool_name).grep(/\Amcp__/).size, "beta's three, none of alpha's"
  end

  # The sidecar adds its abilities' tools (agent/own-tools.json), and the
  # model sees them beside the declared ones: the limit is on what it sees.
  test "the sidecar's own tools count: an agent with a connector of the limit's tools is held to the limit the model sees" do
    own = %w[ codemode subagent message_helper web_search tool_search ]
    assert_equal %w[ codemode subagents web_search ], @agent.capabilities
    connector("alpha", Agent::TOOL_LIMIT - @agent.tools([]).size)

    definition = @agent.reload.conversation.definition
    assert_equal Agent::TOOL_LIMIT, definition[:tools].size + own.size, "what the model sees"
    assert_equal own.size, definition[:lookup].pluck(:name).grep(/\Amcp__alpha__/).size, "the connector's last tools looked up instead"
    assert_equal Agent::TOOL_LIMIT + own.size, @agent.tool_count, "the meter counts what it would see"
  end

  test "a computer's tools count too" do
    @agent.create_computer!(provider: "local", state: "on")
    assert_equal %w[ codemode subagent message_helper web_search read write edit bash visit_website ], @agent.reload.sidecar_tool_names
  end

  test "even a computer agent with overfilled core connectors declares fewer than 60 tools" do
    @agent.create_computer!(provider: "sprites", state: "on")
    @agent.create_campfire_bot!(bot_key: "4-abc123")
    connector("alpha", 65)
    with_setting(:campfire, :url, "http://example-campfire") do
      definition = @agent.reload.conversation.definition
      declared = definition.fetch(:tools).pluck(:name)
      looked_up = definition.fetch(:lookup).pluck(:name)
      count = declared.size + @agent.sidecar_tool_names.size + @agent.lookup_sidecar_tool_names.size

      assert_operator count, :<, 60, "the model needs room to load tools it looks up"
      assert_includes declared, "campfire_say", "answering the room does not need a lookup"
      assert_includes looked_up, "campfire_rooms", "listing rooms is occasional"
      assert_includes looked_up, "mcp__alpha__tool_64", "the connector's overflow is still reachable"
    end
  end

  # The sidecar offers tool_search beside lookup tools (agent/own-tools.json
  # `lookup`), with code mode or without: it counts.
  test "tool_search counts beside lookup tools, with code mode or without" do
    connector("alpha", Agent::TOOL_LIMIT + 1 - @own)
    definition = @agent.reload.conversation.definition
    assert definition[:lookup].any?, "its looked-up tools go to the sidecar"
    assert_equal Agent::TOOL_LIMIT, definition[:tools].size + @agent.sidecar_tool_names.size + 1, "what the model sees, tool_search among it"
    assert_equal Agent::TOOL_LIMIT + 1, @agent.tool_count, "the meter counts it too"

    @agent.update!(capabilities: %w[ subagents web_search ])
    definition = @agent.reload.conversation.definition
    assert definition[:lookup].any?, "without code mode too"
    assert_equal @agent.tool_count, definition[:tools].size + @agent.sidecar_tool_names.size + 1, "tool_search among what the model sees"
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
      own = @agent.reload.tools([]).size + @sidecar
      assert_empty Tool::Catalog::CAMPFIRE.map(&:tool_name) - @agent.own_tools.map(&:tool_name), "every Campfire tool, with no tool_names change"
      connector("alpha", Agent::TOOL_LIMIT + 1 - own)

      tools = @agent.reload.conversation.tools
      names = tools.map(&:tool_name)
      assert_equal Agent::TOOL_LIMIT - @sidecar, tools.size
      assert_includes names, "campfire_history"
      assert_equal 1, @agent.conversation.lookup_tools.map(&:tool_name).grep(/\Amcp__/).size, "one of alpha's looked up"
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
