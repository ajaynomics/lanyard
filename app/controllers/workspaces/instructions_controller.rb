# The owner changes the workspace's shared instructions, which reach every
# one of its agents on its next message. Anyone else finds no such workspace.
class Workspaces::InstructionsController < ApplicationController
  def update
    @workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id])
    @workspace.change_instructions(params.expect(workspace: [ :instructions ])[:instructions], by: Current.user)
    redirect_to @workspace, status: :see_other, notice: "Saved. Every agent here follows these from its next message."
  rescue ActiveRecord::RecordInvalid
    render "workspaces/show", status: :unprocessable_entity
  end
end
