# Lists a server's tools away from the request: the server may be slow, and the
# call must not sit inside a transaction. The settings page redraws when done.
class McpServerRefreshJob < ApplicationJob
  discard_on ActiveJob::DeserializationError # the server was removed meanwhile

  def perform(mcp_server)
    mcp_server.refresh
  end
end
