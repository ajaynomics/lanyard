module Agents
  class ComputersController < ApplicationController
    def update
      agent = Current.user.agents.find(params[:agent_id])
      computer = agent.computer || agent.build_computer
      if computer.update(params.expect(computer: %i[ provider state notes_file ]))
        redirect_to agent, notice: computer.on? ? "Computer on. #{agent} can use files and a shell from the next message." :
          "Computer off. #{agent} has no files or shell from the next message."
      else
        redirect_to agent, alert: computer.errors.full_messages.to_sentence
      end
    end
  end
end
