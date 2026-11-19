# The owner removes a member, and a member leaves; nobody removes the owner.
# The person is out on their next request (Authentication#enter_workspace);
# someone leaving their only way into the install is signed out, told why.
class Workspaces::MembershipsController < ApplicationController
  def destroy
    workspace = Current.user.workspaces.shared.find(params[:workspace_id])
    membership = workspace.memberships.find(params[:id])
    return head :forbidden unless membership.removable_by?(Current.user)

    membership.destroy!
    if membership.user != Current.user
      redirect_to workspace_path(workspace), status: :see_other
    elsif Admission.admits?(Current.email)
      # Left from its page in the phone app's sheet: the sheet closes on the list.
      refresh_or_redirect_to root_path, status: :see_other
    else
      reset_session
      redirect_to sign_in_path, status: :see_other, notice: "You left #{workspace}, and with it this install."
    end
  end
end
