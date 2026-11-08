module Agents
  # The ways others reach the agent, where the install has them: its email
  # address, Concourse and Campfire.
  class ChannelsController < ApplicationController
    include AgentSettings

    def show
    end
  end
end
