# The `mcp` gem's transport for a command connector: each JSON-RPC message
# goes to the sidecar, which passes it to the command running on the conversation's
# own computer and brings back the reply (docs/design/CONTRACT.md). The
# sidecar makes the MCP handshake when it starts the command, so this has no
# `connect` and the gem skips its own.
class McpServer::CommandTransport
  # Waking a sleeping Sprite takes up to two minutes; then the call has its 30 seconds.
  READ_TIMEOUT = 180

  def initialize(server, conversation)
    raise McpServer::Unreachable, "#{server} runs on an agent's computer. Refresh it from an agent's Connectors page." unless conversation
    raise McpServer::Unreachable, "#{server} runs on the agent's computer, and #{conversation.agent} has none switched on." unless server.usable_by?(conversation)
    @server, @conversation = server, conversation
  end

  def send_request(request:)
    DurableAssistants::PiDurable::Client.new.connector_message(@conversation.access, @conversation.durable_id, name: @server.name,
      computer: @conversation.agent.computer.descriptor, entry: @server.launch, message: request, read_timeout: READ_TIMEOUT).fetch("message")
  rescue DurableAssistants::PiDurable::Client::Error => error
    raise McpServer::Unreachable, error.category == "computers_busy" ? "Too many computers are awake; try #{@server} again shortly." :
      "Could not reach #{@server} on #{@conversation}'s computer."
  rescue KeyError
    raise McpServer::Unreachable, "#{@server} sent no answer."
  end

  def close = nil
end
