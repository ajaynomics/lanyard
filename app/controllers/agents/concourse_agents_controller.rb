module Agents
  # Taking the agent off one Concourse network, from its Channels page:
  # Concourse retires it there, then its credential is forgotten
  # (ConcourseAgent#disconnect). Joining is Agents::ConcourseJoinsController.
  class ConcourseAgentsController < ApplicationController
    def destroy
      agent = Current.user.agents.find(params[:agent_id])
      concourse_agent = agent.concourse_agents.find(params[:id])
      # Named by its network only where there is more than one.
      where = agent.concourse_agents.many? ? concourse_agent.organization : "Concourse"
      concourse_agent.disconnect
      redirect_to agent_channels_path(agent), notice: "#{agent} is no longer on #{where}."
    rescue DurableAssistants::Concourse::Client::Error => problem
      redirect_to agent_channels_path(agent), alert: "#{agent} is still on #{where}: #{problem.message}#{" Try again." unless problem.reason == "not_a_connected_agent"}"
    end
  end
end
