require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

class McpServerTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper

  setup do
    @bot = create_user.bots.sole
  end

  test "a name is a short slug, once per bot" do
    assert @bot.mcp_servers.create(name: "wiki_2", url: MCP_URL).persisted?
    assert_not @bot.mcp_servers.new(name: "wiki_2", url: MCP_URL).valid?
    %w[ Wiki 2wiki wiki-two ].each { assert_not @bot.mcp_servers.new(name: it, url: MCP_URL).valid?, it }
    assert @bot.mcp_servers.new(name: "wiki", url: MCP_URL).valid?
  end

  test "the token travels only over https, or plain http to this machine" do
    assert @bot.mcp_servers.new(name: "a", url: "http://localhost:8080/mcp").valid?
    assert @bot.mcp_servers.new(name: "a", url: "http://127.0.0.1/mcp").valid?
    assert_not @bot.mcp_servers.new(name: "a", url: "http://mcp.example.test/mcp").valid?
    assert_not @bot.mcp_servers.new(name: "a", url: "ftp://mcp.example.test").valid?
    assert_not @bot.mcp_servers.new(name: "a", url: "not a url").valid?
  end

  test "the token is stored encrypted" do
    server = @bot.mcp_servers.create!(name: "wiki", url: MCP_URL, token: "secret-token-1")

    assert_equal "secret-token-1", server.reload.token
    assert_not_includes server.ciphertext_for(:token), "secret-token-1"
  end

  test "a refresh lists the server's tools with the bearer token" do
    stub_mcp_server(tools: [ mcp_tool("search", annotations: { readOnlyHint: true },
      properties: { query: { type: "string" } }, required: %w[ query ]) ])
    server = @bot.mcp_servers.create!(name: "wiki", url: MCP_URL, token: "secret-token-1")

    server.refresh

    assert_equal [ { "name" => "search", "description" => "Does search.",
      "input_schema" => { "type" => "object", "properties" => { "query" => { "type" => "string" } }, "required" => %w[ query ] },
      "annotations" => { "readOnlyHint" => true } } ], server.reload.tools
    assert_nil server.refresh_error
    assert_not server.refreshing?
    assert_requested :post, MCP_URL, headers: { "Authorization" => "Bearer secret-token-1" }, times: 3
  end

  test "a server that cannot be reached keeps its tools and says why" do
    server = create_mcp_server(@bot, tools: [ mcp_tool("search") ])
    stub_request(:post, MCP_URL).to_return(status: 401)

    server.refresh

    assert_equal %w[ search ], server.reload.tools.pluck("name")
    assert_match(/Could not reach wiki: You are unauthorized/, server.refresh_error)
  end

  test "a server that would give the bot too many tools is refused on refresh" do
    stub_mcp_server(tools: Array.new(Bot::TOOL_LIMIT) { mcp_tool("tool_#{it}") })
    server = @bot.mcp_servers.create!(name: "wiki", url: MCP_URL)

    server.refresh

    assert_empty server.reload.tools
    assert_match(/offers 64 tools; Avery can have 64 in all and already has 5/, server.refresh_error)
  end
end
