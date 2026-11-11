module Agents
  # Join Concourse, or another network on it: the person's browser goes to
  # Concourse's page to sign in, pick an organization and approve, and comes
  # back to ConcourseCallbacksController. Which organization is known only
  # then (ConcourseAgent::Join#finish): a new one is added; joining one again,
  # after a decline or once Concourse no longer accepts the agent there,
  # replaces the old credential once the new one is in hand.
  class ConcourseJoinsController < ApplicationController
    # The page an agent links to when asked to join (Tool::JoinConcourse): one
    # button, since leaving for Concourse is the person's step, not the agent's.
    def new
      @agent = Current.user.agents.find(params[:agent_id])
      render layout: "settings"
    end

    def create
      agent = Current.user.agents.find(params[:agent_id])
      # The old record stays until the new one is made (ConcourseAgent::Join#finish), so cancelling at Concourse keeps it.
      join = ConcourseAgent::Join.start(agent)
      session[:concourse_join] = join.to_h
      redirect_to join.url(agent), allow_other_host: true
    end
  end
end
