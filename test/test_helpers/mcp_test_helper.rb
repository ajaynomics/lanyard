# A stand-in MCP server over WebMock: JSON-RPC over Streamable HTTP, answering
# the 2025 handshake, tools/list and tools/call. `calls` maps a tool name to a
# block that takes the arguments and returns the tools/call result.
module McpTestHelper
  MCP_URL = "https://mcp.example.test/mcp".freeze

  def stub_mcp_server(url: MCP_URL, tools: [], calls: {})
    stub_request(:post, url).to_return do |request|
      message = JSON.parse(request.body)
      case message["method"]
      when "initialize"
        mcp_reply(message, protocolVersion: MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION,
          capabilities: { tools: {} }, serverInfo: { name: "stand-in", version: "1" })
      when "notifications/initialized" then { status: 202 }
      when "tools/list" then mcp_reply(message, tools: tools)
      when "tools/call"
        params = message["params"]
        mcp_reply(message, calls.fetch(params["name"]).call(params["arguments"]))
      else raise "unexpected #{message['method']}"
      end
    end
  end

  # The sidecar's command-connector endpoint for one agent, answering tools/list
  # and tools/call as the command on the agent's computer would.
  def stub_command_connector(conversation, name:, tools: [], calls: {})
    stub_request(:post, "#{AgentTestHelper::SIDECAR}/v1/conversations/#{conversation.durable_id}/connectors/#{name}/rpc").to_return do |request|
      message = JSON.parse(request.body)["message"]
      result = case message["method"]
      when "tools/list" then { tools: tools }
      when "tools/call" then calls.fetch(message.dig("params", "name")).call(message.dig("params", "arguments"))
      else raise "unexpected #{message['method']}"
      end
      { status: 200, headers: { "Content-Type" => "application/json" }, body: { message: { jsonrpc: "2.0", id: message["id"], result: result } }.to_json }
    end
  end

  def mcp_tool(name, description: "Does #{name}.", properties: {}, required: [], annotations: nil)
    { name: name, description: description, annotations: annotations,
      inputSchema: { type: "object", properties: properties, required: required } }.compact
  end

  # One of the agent's owner's connectors, or with `conversation:`, that agent's own.
  def create_mcp_server(agent, name: "wiki", url: MCP_URL, tools: [], token: nil, conversation: nil)
    listed = tools.map { { "name" => it[:name], "description" => it[:description], "input_schema" => it[:inputSchema].deep_stringify_keys,
      "annotations" => (it[:annotations] || {}).deep_stringify_keys } }
    agent.user.mcp_servers.create!(name: name, url: url, token: token, tools: listed, refreshed_at: Time.current, conversation: conversation)
  end

  private
    def mcp_reply(message, result)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: { jsonrpc: "2.0", id: message["id"], result: result }.to_json }
    end
end
