module Agents
  # Moving an agent to another of the person's workspaces (Agent::Movable):
  # only its workspace's owner moves it, to one she is in. She then works
  # there, where it is now; anyone else finds no Move.
  class MovesController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.movable_by?(Current.user) }

    def new
    end

    def create
      destination = @agent.destinations_for(Current.user).find(params.expect(move: [ :workspace_id ])[:workspace_id])
      if @agent.move_to(destination, by: Current.user)
        ahoy.track "Agent moved", agent_id: @agent.id
        enter_workspace destination
        redirect_to @agent, status: :see_other, notice: "Moved #{@agent} to #{destination}."
      else
        render :new, status: :unprocessable_entity
      end
    end
  end
end
