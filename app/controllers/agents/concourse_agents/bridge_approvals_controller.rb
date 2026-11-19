module Agents
  module ConcourseAgents
    # The workspace's owner approves an identity outside its home network, a
    # bridge, from the agent's Channels page (ConcourseAgent::Bridge): from
    # then on it reads and sends there. For anyone else it is not found.
    class BridgeApprovalsController < ApplicationController
      include AgentSettings

      before_action { head :not_found unless @agent.owned_by?(Current.user) }

      def create
        concourse_agent = @agent.concourse_agents.find(params[:concourse_agent_id])
        return head :not_found unless concourse_agent.waiting_for_owner?
        concourse_agent.approve_bridge(Current.user)
        ahoy.track "Concourse bridge approved", agent_id: @agent.id, network: concourse_agent.organization
        concourse_agent.check
        redirect_to agent_channels_path(@agent), notice: "#{@agent} may now speak on #{concourse_agent.organization}."
      end
    end
  end
end
