module Agents
  # One agent's Helpers panel: its helpers working in the background and its
  # workflows' runs, then those that ended lately (helpers/_panel). Every
  # agent's is HelpersController.
  class HelpersController < ApplicationController
    include AgentSettings

    def index
      @helpers = @agent.helpers.own
      @runs = @agent.workflow_runs
    end
  end
end
