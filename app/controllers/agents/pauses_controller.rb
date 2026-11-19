module Agents
  # The person pauses an agent (create), or resumes it (destroy), which sends
  # every message held meanwhile, in order (Agent::Pausable). From its
  # settings or its thread; back to where it was asked.
  class PausesController < ApplicationController
    before_action { @agent = find_in_workspace(:agents, params[:agent_id]) }

    def create
      @agent.pause
      ahoy.track "Agent paused", agent_id: @agent.id
      redirect_back_or_to @agent, notice: "Paused. #{@agent.name} holds what it is sent until you resume it.", status: :see_other
    end

    def destroy
      @agent.resume
      ahoy.track "Agent resumed", agent_id: @agent.id
      redirect_back_or_to @agent, notice: "Resumed. #{@agent.name} reads what it was sent, in order.", status: :see_other
    end
  end
end
