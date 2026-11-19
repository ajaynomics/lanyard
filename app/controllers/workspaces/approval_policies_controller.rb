# Which calls of a workspace's agents ask a person first (#226,
# Workspace::ApprovalPolicy): its owner's choice alone, a personal workspace's
# too. Blank goes back to the install's default. Anyone else finds no such
# workspace.
class Workspaces::ApprovalPoliciesController < ApplicationController
  def update
    @workspace = Current.user.owned_workspaces.find(params[:workspace_id])
    if @workspace.update(params.expect(workspace: [ :approval_policy ]))
      ahoy.track "Workspace approval policy chosen", workspace_id: @workspace.id
      redirect_to @workspace, status: :see_other, notice: "#{@workspace}: #{@workspace.approvals.to_s.downcase_first}."
    else
      render "workspaces/show", status: :unprocessable_entity
    end
  end
end
