module Agents
  # The ways others reach the agent, where the install has them: its email
  # address, Concourse and Campfire. An agent waiting for an owner's approval
  # on a Concourse network is asked about again, at most once a minute.
  class ChannelsController < ApplicationController
    include AgentSettings

    def show
      @agent.concourse_agents.each(&:recheck) if DurableAssistants::Concourse.configured?
    end
  end
end
