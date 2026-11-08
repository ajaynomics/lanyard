module Agents
  # Taking the agent off Concourse, from its Channels page: Concourse retires
  # it, then its credential is forgotten (ConcourseAgent#disconnect). Joining
  # is Agents::ConcourseJoinsController.
  class ConcourseAgentsController < ApplicationController
    def destroy
      agent = Current.user.agents.find(params[:agent_id])
      agent.concourse_agent&.disconnect
      redirect_to agent_channels_path(agent), notice: "#{agent} is no longer on Concourse."
    rescue DurableAssistants::Concourse::Client::Error => problem
      redirect_to agent_channels_path(agent), alert: "#{agent} is still on Concourse: #{problem.message} Try again."
    end
  end
end
