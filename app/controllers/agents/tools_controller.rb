module Agents
  # Everything the agent can do, in one list grouped by where it comes from,
  # with a switch on each for this agent alone, and a meter of how close it is
  # to the sidecar's limit. A connector's tools are switched off for every
  # agent on its own page (Connectors::ToolsController).
  class ToolsController < ApplicationController
    include AgentSettings

    def index
      @connectors = @agent.conversation.connectors
    end

    def update
      name = params[:name]
      raise ActiveRecord::RecordNotFound, "No tool #{name}" unless switchable?(name)
      if @agent.switch_tool(name, params[:on] == "1")
        saved agent_tools_path(@agent)
      else
        redirect_back_or_to agent_tools_path(@agent), alert: @agent.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private
      # One of the catalogue's tools, an ability, or a tool of a connector it uses.
      def switchable?(name)
        Tool::Catalog.names.include?(name) || Agent.capability_names.include?(name) ||
          @agent.conversation.connectors.flat_map(&:listed_tools).any? { it.tool_name == name }
      end
  end
end
