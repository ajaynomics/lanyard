module Agents
  # The ways others reach the agent, where the install has them: its email
  # address, Concourse and Campfire. An agent waiting for an owner's approval
  # on Concourse is asked about again, at most once a minute.
  class ChannelsController < ApplicationController
    include AgentSettings

    def show
      @agent.concourse_agent&.recheck if DurableAssistants::Concourse.configured?
    end
  end
end
