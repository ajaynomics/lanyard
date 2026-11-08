module Agents
  # Join Concourse: the person's browser goes to Concourse's page to sign in,
  # pick an organization and approve, and comes back to
  # ConcourseCallbacksController. Joining again, after a decline or once
  # Concourse no longer accepts the agent, forgets the old credential first.
  class ConcourseJoinsController < ApplicationController
    # The page an agent links to when asked to join (Tool::JoinConcourse): one
    # button, since leaving for Concourse is the person's step, not the agent's.
    def new
      @agent = Current.user.agents.find(params[:agent_id])
      render layout: "settings"
    end

    def create
      agent = Current.user.agents.find(params[:agent_id])
      if agent.concourse_agent&.joined?
        return redirect_to agent_channels_path(agent), alert: "#{agent} is on Concourse already. Disconnect it before joining again."
      end

      agent.concourse_agent&.destroy!
      join = ConcourseAgent::Join.start(agent)
      session[:concourse_join] = join.to_h
      redirect_to join.url(agent), allow_other_host: true
    end
  end
end
