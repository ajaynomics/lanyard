module Agents
  # Who the agent is: its instructions, saved by the person (or by the agent,
  # when asked, through change_yourself). Every saved version is kept.
  class InstructionsController < ApplicationController
    include AgentSettings

    def show
    end

    def update
      if @agent.update(params.expect(agent: [ :instructions ]))
        redirect_to agent_instructions_path(@agent), notice: "Saved. #{@agent} follows these from the next message.", status: :see_other
      else
        render :show, status: :unprocessable_entity
      end
    end
  end
end
