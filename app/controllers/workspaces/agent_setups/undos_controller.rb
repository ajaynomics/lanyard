module Workspaces::AgentSetups
  class UndosController < BaseController
    def create
      @setup.undo!(by: Current.user)
      show_setup("Reporting line removed and thread archived. No data deleted.")
    rescue Workspace::AgentSetup::Conflict => problem
      @setup.errors.add(:base, problem.message)
      render "workspaces/agent_setups/show", status: :conflict
    end
  end
end
