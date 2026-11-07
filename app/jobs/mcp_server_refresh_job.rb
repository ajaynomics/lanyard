# Lists a server's tools away from the request: the server may be slow, and the
# call must not sit inside a transaction. The settings page redraws when done.
class McpServerRefreshJob < ApplicationJob
  discard_on ActiveJob::DeserializationError # the server was removed meanwhile

  # `conversation`: the conversation whose computer runs a command connector.
  def perform(mcp_server, conversation = mcp_server.conversation)
    mcp_server.refresh(conversation)
  end
end
