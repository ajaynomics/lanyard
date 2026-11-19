# The owner hands a shared workspace to one of its members, and stays in it as
# a member; from then on only the new owner invites and removes. Anyone else
# finds no such workspace.
class Workspaces::OwnershipsController < ApplicationController
  def create
    workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id])
    membership = workspace.memberships.find(params[:membership_id])
    membership.take_ownership
    redirect_to workspace, status: :see_other, notice: "#{membership.user} owns #{workspace} now."
  end
end
