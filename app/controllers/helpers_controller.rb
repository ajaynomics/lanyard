# The Helpers panel for a workspace (WorkspaceScoped): every agent's helpers
# working in the background and its workflows' runs, then those that ended
# lately (helpers/_panel). Each agent's own is Agents::HelpersController.
class HelpersController < ApplicationController
  include WorkspaceScoped
  layout "settings"

  def index
    @helpers = Current.workspace.helpers.own
    @runs = Current.workspace.workflow_runs
  end
end
