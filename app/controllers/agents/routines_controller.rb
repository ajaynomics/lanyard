module Agents
  # The person pauses, resumes or deletes a routine on the agent's page; the
  # agent adds them when asked (Tool::AddRoutine).
  class RoutinesController < ApplicationController
    before_action :set_routine

    def update
      @routine.update!(paused_at: params.expect(routine: [ :paused ])[:paused] == "1" ? Time.current : nil)
      redirect_to @routine.agent, notice: @routine.paused? ? "Paused." : "Resumed. Next: #{l(@routine.next_run_at.in_time_zone(@routine.agent.time_zone), format: :long)}."
    end

    def destroy
      @routine.destroy!
      redirect_to @routine.agent, notice: "Deleted."
    end

    private
      def set_routine
        @routine = Current.user.agents.find(params[:agent_id]).routines.find(params[:id])
      end
  end
end
