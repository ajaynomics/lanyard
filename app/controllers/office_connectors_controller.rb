# Turns one of the install's connectors on in the workspace (McpServer.turn_on):
# its owner's choice, or the install's owner's. Any member switches it off
# again on its own page, as any connector.
class OfficeConnectorsController < ApplicationController
  def create
    name = params.expect(:name)
    raise ActiveRecord::RecordNotFound unless McpServer.install_entries.key?(name) && Current.workspace.turns_on_install_connectors?(Current.user)
    connector = McpServer.turn_on(Current.workspace, name)
    if connector.errors.none?
      redirect_to connector_path(connector), notice: "#{name} is on for every agent here. Listing its tools…"
    else
      redirect_to connectors_path, alert: connector.errors.full_messages.to_sentence
    end
  end
end
