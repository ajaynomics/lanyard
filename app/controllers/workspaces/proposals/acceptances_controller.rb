# The owner accepts a member's proposal: it becomes the workspace's shared
# instructions, kept as a revision naming both. Anyone else finds no such workspace.
class Workspaces::Proposals::AcceptancesController < ApplicationController
  def create
    workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id])
    workspace.proposals.find(params[:proposal_id]).accept(by: Current.user)
    redirect_to workspace, status: :see_other, notice: "Accepted. Every agent here follows these from its next message."
  end
end
