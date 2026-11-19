# An admin's yes to an invitation waiting in Settings: its email may sign in
# from now, and the install emails it, once. To anyone else it does not exist.
class Settings::Invitations::ApprovalsController < ApplicationController
  before_action { raise ActionController::RoutingError, "Not Found" unless Current.admin? }

  def create
    invitation = Workspace::Invitation.awaiting_approval.find(params[:invitation_id]) # tenancy-ok: the install's admins answer for who comes in, whichever workspace invites
    invitation.approve(by: Current.user)
    redirect_to settings_invitations_path, status: :see_other, notice: "Approved #{invitation.email}."
  end
end
