# Settings, Invitations: the people a workspace's owner invited, waiting for
# an admin's yes before they may sign in or are emailed (Workspace::Invitation).
# An admin approves one (Settings::Invitations::ApprovalsController) or
# declines it, which cancels it. To anyone else it does not exist.
class Settings::InvitationsController < ApplicationController
  layout "settings"

  before_action { raise ActionController::RoutingError, "Not Found" unless Current.admin? }

  def index
    @invitations = Workspace::Invitation.awaiting_approval.includes(:workspace, :inviter).order(:created_at) # tenancy-ok: the install's admins answer for who comes in, whichever workspace invites
  end

  def destroy
    invitation = Workspace::Invitation.awaiting_approval.find(params[:id]) # tenancy-ok: the install's admins answer for who comes in, whichever workspace invites
    invitation.destroy!
    redirect_to settings_invitations_path, status: :see_other, notice: "Declined #{invitation.email}."
  end
end
