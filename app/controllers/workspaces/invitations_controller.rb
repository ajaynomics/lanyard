# The owner of a shared workspace invites an email and cancels an invitation.
# Anyone else finds no such workspace. What an invitation does, and that an
# install serving one person invites nobody, is the workspace's
# (Workspace#invite), as an agent's invite_to_workspace does it.
class Workspaces::InvitationsController < ApplicationController
  before_action :set_workspace

  def create
    @invitation = @workspace.invite(invitation_params[:email], by: Current.user, admin: Current.admin?)
    if @invitation.accepted?
      redirect_to @workspace, status: :see_other, notice: "Added #{@invitation.invitee}."
    elsif @invitation.persisted?
      redirect_to @workspace, status: :see_other, notice: invited_notice
    elsif @invitation.refused_for_one_owner?
      redirect_to @workspace, status: :see_other, alert: Workspace::Invitation::REFUSED_FOR_ONE_OWNER
    else
      render "workspaces/show", status: :unprocessable_entity
    end
  end

  def destroy
    @workspace.invitations.find(params[:id]).destroy!
    redirect_to @workspace, status: :see_other
  end

  private
    def set_workspace
      @workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id])
    end

    def invited_notice
      if @invitation.awaiting_approval?
        "Invited #{@invitation.email}. They can sign in once an admin approves it."
      else
        "Invited #{@invitation.email}."
      end
    end

    def invitation_params = params.expect(invitation: [ :email ])
end
