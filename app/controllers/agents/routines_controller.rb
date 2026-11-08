module Agents
  # The person pauses, resumes or deletes a routine in the agent's settings;
  # the agent adds them when asked (Tool::AddRoutine).
  class RoutinesController < ApplicationController
    include AgentSettings

    before_action :set_routine, only: %i[ update destroy ]

    def index
    end

    def update
      @routine.update!(paused_at: params.expect(routine: [ :paused ])[:paused] == "1" ? Time.current : nil)
      redirect_to agent_routines_path(@agent), notice: @routine.paused? ? "Paused." : "Resumed. Next: #{l(@routine.next_run_at.in_time_zone(@agent.time_zone), format: :long)}."
    end

    def destroy
      @routine.destroy!
      redirect_to agent_routines_path(@agent), notice: "Deleted."
    end

    private
      def set_routine
        @routine = @agent.routines.find(params[:id])
      end
  end
end
