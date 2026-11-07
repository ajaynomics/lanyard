# Lists a connector's tools again. A command connector runs on an agent's
# computer: its own agent's, or for one of the person's, the agent whose
# Connectors page asked (agent_id).
class Connectors::RefreshesController < ApplicationController
  include ConnectorPages

  def create
    connector = Current.user.mcp_servers.find(params[:connector_id])
    agent = Current.user.conversations.find(params[:agent_id]) if params[:agent_id].present?
    McpServerRefreshJob.perform_later(connector, connector.conversation || agent)
    redirect_to agent ? conversation_connectors_path(agent) : connector_page(connector), notice: "Listing #{connector}'s tools again…"
  end
end
