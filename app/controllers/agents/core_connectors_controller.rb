module Agents
  # A switch on the agent's Tools for each of the person's connectors: core,
  # its tools in every message, or looked up when needed. For this agent
  # alone; checked against its limit only (Agent::CoreConnector). An office
  # connector the install decides for has no switch.
  class CoreConnectorsController < ApplicationController
    include AgentSettings

    def update
      connector = Current.workspace.mcp_servers.global.find(params[:id])
      raise ActiveRecord::RecordNotFound, "The install decides #{connector}" if connector.install_entry&.key?(:loaded)
      if params[:on] == "1"
        core = @agent.core_connectors.find_or_initialize_by(mcp_server: connector)
        return redirect_back_or_to agent_tools_path(@agent), alert: core.errors.full_messages.to_sentence, status: :see_other unless core.save
      else
        @agent.core_connectors.where(mcp_server: connector).delete_all
      end
      @agent.touch
      saved agent_tools_path(@agent)
    end
  end
end
