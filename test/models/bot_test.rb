require "test_helper"
require_relative "../test_helpers/agent_test_helper"

require_relative "../test_helpers/mcp_test_helper"

class BotTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper

  test "a new person gets avery from the reviewed template, once" do
    alice = create_user(name: "Alice")
    User.sign_in!(sub: "sub-alice", email: "alice@example.com", name: "Alice")

    bot = alice.bots.sole
    assert_equal "Avery", bot.name
    assert_equal "local/avery-local", bot.model
    assert_includes bot.instructions, "You are Avery"
    assert_equal %w[ current_time remember_note list_notes forget_note ask_person ], bot.tool_names
  end

  test "every edit to what the bot is keeps a revision" do
    bot = create_user.bots.sole
    bot.update!(instructions: "Be terse.")
    bot.update!(name: "Renamed")

    assert_equal "Be terse.", bot.revisions.last.instructions
    assert_equal 2, bot.revisions.count
  end

  test "only catalogued tools and allowed models are accepted" do
    bot = create_user.bots.sole

    assert_not bot.update(tool_names: %w[ current_time rm_rf ])
    assert_includes bot.errors[:tool_names].first, "rm_rf"
    assert_not bot.update(model: "someone/else")
  end

  test "the definition names itself by its own digest and changes when the bot does" do
    bot = create_user.bots.sole
    definition = bot.definition

    assert_equal Agent::Canonical.digest(definition.except(:digest)), definition[:digest]
    assert_equal %w[ current_time remember_note list_notes forget_note ask_person ], definition[:tools].pluck(:name)
    assert_equal false, definition[:tools].first[:parameters]["additionalProperties"]

    bot.update!(instructions: "Different.")
    assert_not_equal definition[:digest], bot.definition[:digest]
  end

  test "every catalogue pattern is valid ECMA-262, the sidecar's regex dialect" do
    patterns = Tool::Catalog::TOOLS.values.flat_map { it.arguments.values }.filter_map { it["pattern"] }

    assert_not_empty patterns
    patterns.each { assert_no_match(/\\[AzZ]|\(\?[<im-]/, it, "Ruby-only syntax in #{it}") }
  end

  test "a bot has at most the sidecar's limit of tools, its MCP servers' included" do
    bot = create_user.bots.sole
    create_mcp_server(bot, tools: Array.new(Bot::TOOL_LIMIT - 5) { mcp_tool("tool_#{it}") })

    assert_equal Bot::TOOL_LIMIT, bot.definition[:tools].size
    server = bot.mcp_servers.new(name: "more", url: MCP_URL, tools: [ { "name" => "one" } ])
    assert_not server.valid?
    assert_match(/already has 64/, server.errors.full_messages.to_sentence)
  end
end
