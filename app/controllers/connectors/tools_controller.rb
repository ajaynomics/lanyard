# One of a connector's tools switched on or off for every agent that uses it,
# on the connector's page. An agent's own switch is in its Tools
# (Agents::ToolsController).
class Connectors::ToolsController < ApplicationController
  include ConnectorPages

  def update
    connector = Current.user.mcp_servers.find(params[:connector_id])
    name = params[:name]
    raise ActiveRecord::RecordNotFound, "#{connector} lists no tool #{name}" unless connector.tools.any? { it["name"] == name }
    off = params[:on] == "1" ? connector.disabled_tools - [ name ] : connector.disabled_tools | [ name ]
    if connector.update(disabled_tools: off)
      saved connector_page(connector)
    else
      redirect_back_or_to connector_page(connector), alert: connector.errors.full_messages.to_sentence, status: :see_other
    end
  end
end
