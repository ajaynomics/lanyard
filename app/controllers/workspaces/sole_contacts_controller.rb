# A member chooses the one agent of a shared workspace that alone may contact
# them, or any, and the number it knows them by (Workspace::Membership#sole_contact).
# Each sets their own; nobody sets another's.
class Workspaces::SoleContactsController < ApplicationController
  def update
    @workspace = Current.user.workspaces.shared.find(params[:workspace_id])
    @membership = @workspace.memberships.find_by!(user: Current.user)
    choice = params.expect(membership: [ :sole_contact_id, :phone_number ])
    if @membership.update(sole_contact: @workspace.agents.find_by(id: choice[:sole_contact_id].presence), phone_number: choice[:phone_number])
      redirect_to @workspace, status: :see_other,
        notice: @membership.sole_contact ? "Only #{@membership.sole_contact} contacts you here." : "Any agent here may contact you."
    else
      render "workspaces/show", status: :unprocessable_entity
    end
  end
end
