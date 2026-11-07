require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/mcp_test_helper"

class Tool::McpTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper

  setup do
    @bot = create_user.bots.sole
  end

  test "a server's tool joins the definition under a name the sidecar accepts" do
    create_mcp_server(@bot, tools: [ mcp_tool("Get-Page.v2", properties: { id: { type: "string" } }), mcp_tool("x" * 80) ])
    declarations = @bot.definition[:tools].last(2)

    assert_equal "mcp__wiki__get_page_v2", declarations.first[:name]
    assert_equal({ "type" => "object", "properties" => { "id" => { "type" => "string" } }, "required" => [] }, declarations.first[:parameters])
    assert_equal 64, declarations.last[:name].length
    declarations.each { assert_match(/\A[a-z][a-z0-9_]{0,63}\z/, it[:name]) }
    assert_equal "Get-Page.v2", @bot.tool("mcp__wiki__get_page_v2").listing["name"]
  end

  test "only a tool the server marks read-only runs without asking" do
    create_mcp_server(@bot, tools: [ mcp_tool("read", annotations: { readOnlyHint: true }),
      mcp_tool("write", annotations: { readOnlyHint: false }), mcp_tool("unmarked") ])

    assert_nil @bot.tool("mcp__wiki__read").asks
    assert_equal :approval, @bot.tool("mcp__wiki__write").asks
    assert_equal :approval, @bot.tool("mcp__wiki__unmarked").asks
    assert_equal :external, @bot.tool("mcp__wiki__read").effect
  end

  test "arguments are checked against the server's schema" do
    create_mcp_server(@bot, tools: [ mcp_tool("search", properties: { query: { type: "string" } }, required: %w[ query ]) ])
    tool = @bot.tool("mcp__wiki__search")

    assert_empty tool.errors_for("query" => "rails")
    assert_not_empty tool.errors_for("query" => 1)
    assert_not_empty tool.errors_for({})
  end

  test "a call returns the text, or the structured content when there is some" do
    create_mcp_server(@bot, tools: [ mcp_tool("search"), mcp_tool("count") ])
    stub_mcp_server(calls: {
      "search" => ->(arguments) { { content: [ { type: "text", text: "found #{arguments['q']}" }, { type: "image", mimeType: "image/png", data: "x" } ] } },
      "count" => ->(_) { { content: [ { type: "text", text: "{\"n\":2}" } ], structuredContent: { n: 2 } } }
    })
    invocation = Invocation.new(conversation: create_conversation(@bot))

    assert_equal({ text: "found it\n\n[image image/png]" }, @bot.tool("mcp__wiki__search").new(invocation).call(q: "it"))
    assert_equal({ "n" => 2 }, @bot.tool("mcp__wiki__count").new(invocation).call)
  end

  test "a tool's own error and an unreachable server are refusals the model reads" do
    create_mcp_server(@bot, tools: [ mcp_tool("search") ])
    invocation = Invocation.new(conversation: create_conversation(@bot))
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "rate limited" } ], isError: true } } })

    error = assert_raises(Tool::Refusal) { @bot.tool("mcp__wiki__search").new(invocation).call }
    assert_equal "mcp__wiki__search failed: rate limited", error.message

    stub_request(:post, MCP_URL).to_return(status: 503)
    error = assert_raises(Tool::Refusal) { @bot.tool("mcp__wiki__search").new(invocation).call }
    assert_match(/Could not reach wiki/, error.message)
  end

  test "a call refused for sign-in tells the model to ask the person, not to retry" do
    create_mcp_server(@bot, tools: [ mcp_tool("search") ])
    invocation = Invocation.new(conversation: create_conversation(@bot))
    stub_request(:post, MCP_URL).to_return(status: 401)

    error = assert_raises(Tool::Refusal) { @bot.tool("mcp__wiki__search").new(invocation).call }
    assert_equal "wiki needs the person to sign in again, on its Connectors page. Tell them; don't retry until they have.", error.message
  end
end
