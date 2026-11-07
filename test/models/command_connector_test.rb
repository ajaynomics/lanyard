require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# pi's `command` connectors, which run on each agent's own computer. Rails is
# the MCP client; the sidecar's endpoint is stubbed (WebMock).
class CommandConnectorTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper

  ENTRY = { "command" => "npx", "args" => [ "-y", "files-mcp" ], "env" => { "FILES_TOKEN" => "secret-env-1" }, "cwd" => "work" }.freeze
  RPC = %r{\A#{Regexp.escape(SIDECAR)}/v1/conversations/\d+/connectors/files/rpc\z}

  setup do
    install_sidecar_settings
    @bot = create_user.bots.sole
    @user = @bot.user
    @agent = create_conversation(@bot, durable_id: "1")
  end
  teardown { remove_sidecar_settings }

  test "pi's command entry is accepted, with literal values only" do
    attributes = McpServer::Entry.parse({ mcpServers: { files: ENTRY.merge("type" => "stdio") } }.to_json)["files"]
    assert_equal({ name: "files", enabled: true, command: "npx", args: [ "-y", "files-mcp" ], env: { "FILES_TOKEN" => "secret-env-1" }, cwd: "work" }, attributes)

    { { "env" => { "T" => "${TOKEN}" } } => /value itself/, { "args" => [ "!gh auth token" ] } => /value itself/,
      { "url" => MCP_URL } => /not both|pick one/, { "type" => "http" } => /stdio/, { "args" => "-y" } => /list of text/ }.each do |change, reason|
      error = assert_raises(McpServer::Entry::Invalid) { McpServer::Entry.parse({ files: ENTRY.merge(change) }.to_json) }
      assert_match reason, error.message
    end
  end

  test "its env is stored encrypted, and it needs no web address" do
    server = @user.mcp_servers.create!(name: "files", command: "npx", args: [ "-y" ], env: { "FILES_TOKEN" => "secret-env-1" })

    assert_equal({ "FILES_TOKEN" => "secret-env-1" }, server.reload.env)
    assert_not_includes server.ciphertext_for(:env), "secret-env-1"
    assert_not @user.mcp_servers.new(name: "both", command: "npx", url: MCP_URL).valid?
  end

  test "an agent's own lists its tools and calls them on that agent's computer, through the sidecar" do
    @bot.create_computer!(provider: "local", state: "on")
    server = @user.mcp_servers.create!(ENTRY.symbolize_keys.merge(name: "files", conversation: @agent))
    stub_command_connector(@agent, name: "files", tools: [ mcp_tool("read", annotations: { readOnlyHint: true }) ],
      calls: { "read" => ->(arguments) { { content: [ { type: "text", text: "read #{arguments['path']}" } ] } } })

    server.refresh
    assert_nil server.reload.refresh_error
    assert_equal %w[ read ], server.tools.pluck("name")

    tool = @agent.tool("mcp__files__read")
    invocation = @agent.invocations.create!(task_id: "7", call_id: "c1", tool_name: tool.tool_name, arguments: { "path" => "a.txt" }, digest: "d")
    assert_equal({ text: "read a.txt" }, tool.new(invocation).call(path: "a.txt"))
    assert_requested :post, RPC, times: 2 do |request|
      body = JSON.parse(request.body)
      body["entry"] == ENTRY && body["computer"] == { "provider" => "local", "notesFile" => true } &&
        body["actorId"] == @user.id.to_s && body["workspaceId"] == @bot.id.to_s
    end
  end

  test "a person's connector runs separately on each agent's computer, listed from the agent asked" do
    @bot.create_computer!(provider: "local", state: "on")
    other = create_conversation(@bot, durable_id: "2")
    server = @user.mcp_servers.create!(ENTRY.symbolize_keys.merge(name: "files"))

    server.refresh
    assert_match "Refresh it from an agent's Connectors page", server.reload.refresh_error

    stub_command_connector(other, name: "files", tools: [ mcp_tool("read") ])
    server.refresh(other)
    assert_equal %w[ read ], server.reload.tools.pluck("name")
    assert @agent.tool("mcp__files__read")
    assert other.tool("mcp__files__read")
    assert_requested :post, "#{SIDECAR}/v1/conversations/2/connectors/files/rpc"
  end

  test "an agent without a computer that is on gets none of its tools, and is told why" do
    @user.mcp_servers.create!(ENTRY.symbolize_keys.merge(name: "files", tools: [ { "name" => "read" } ]))
    server = @user.mcp_servers.create!(ENTRY.symbolize_keys.merge(name: "mine", conversation: @agent, tools: [ { "name" => "list" } ]))

    assert_empty @agent.connectors
    @bot.create_computer!(provider: "local", state: "off")
    assert_empty @agent.reload.connectors

    server.refresh
    assert_match "#{@bot} has none switched on", server.reload.refresh_error
    assert_not_requested :post, RPC
  end

  test "the computer's own failures read as one sentence" do
    @bot.create_computer!(provider: "sprites", state: "on")
    server = @user.mcp_servers.create!(ENTRY.symbolize_keys.merge(name: "files", conversation: @agent))
    stub_request(:post, RPC).to_return(status: 429, body: { error: "computers_busy" }.to_json)

    server.refresh
    assert_equal "Too many computers are awake; try files again shortly.", server.reload.refresh_error

    stub_request(:post, RPC).to_return(status: 200, body: { message: { jsonrpc: "2.0", id: 1, error: { code: -32000, message: "exited: npm ERR! not found" } } }.to_json)
    server.refresh
    assert_equal "Could not reach files: exited: npm ERR! not found", server.reload.refresh_error
  end
end
