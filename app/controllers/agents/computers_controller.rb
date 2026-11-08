module Agents
  # The agent's computer, in its settings: the kind, on or off, and the notes
  # file. Each change saves as it is made.
  class ComputersController < ApplicationController
    include AgentSettings

    def show
    end

    def update
      computer = @agent.computer || @agent.build_computer
      if computer.update(params.expect(computer: %i[ provider state notes_file ]))
        saved agent_computer_path(@agent)
      else
        redirect_to agent_computer_path(@agent), alert: computer.errors.full_messages.to_sentence
      end
    end
  end
end
