module Agents
  module Computers
    # The agent's own Sprite size (Computer::Size), over its workspace's and
    # within the install's maximum. Only the owner of its workspace sets it;
    # for anyone else it is not there.
    class SizesController < ApplicationController
      include AgentSettings
      before_action { head :not_found unless @agent.owned_by?(Current.user) && @agent.computer&.sprites? }

      def update
        computer = @agent.computer
        if computer.update(params.expect(computer: %i[ cpus memory_mib disk_mib ]))
          saved agent_computer_path(@agent)
        else
          redirect_to agent_computer_path(@agent), alert: computer.errors.full_messages.to_sentence
        end
      end
    end
  end
end
