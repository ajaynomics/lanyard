module Workspaces::AgentSetups
  class ExecutionsController < BaseController
    def create
      @setup.execute!(by: Current.user)
      show_setup("Agent setup recorded.")
    rescue ActiveRecord::RecordInvalid => invalid
      @setup.errors.add(:base, invalid.record.errors.full_messages.to_sentence) unless invalid.record == @setup
      render "workspaces/agent_setups/show", status: :unprocessable_entity
    end
  end
end
