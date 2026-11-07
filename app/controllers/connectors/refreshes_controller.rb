class Connectors::RefreshesController < ApplicationController
  include ConnectorPages

  def create
    connector = Current.user.mcp_servers.find(params[:connector_id])
    McpServerRefreshJob.perform_later(connector)
    redirect_to connector_page(connector), notice: "Listing #{connector}'s tools again…"
  end
end
