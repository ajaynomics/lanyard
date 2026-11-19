# Lists a connector's tools again. A command connector runs on a conversation's
# computer: its own, or for one of the person's, the conversation whose
# Connectors page asked (conversation_id).
class Connectors::RefreshesController < ApplicationController
  include ConnectorPages

  def create
    connector = find_in_workspace(:connectors, params[:connector_id])
    conversation = Current.workspace.conversations.find(params[:conversation_id]) if params[:conversation_id].present?
    McpServerRefreshJob.perform_later(connector, connector.conversation || conversation)
    redirect_to conversation ? conversation_connectors_path(conversation) : connector_page(connector), notice: "Listing #{connector}'s tools again…"
  end
end
