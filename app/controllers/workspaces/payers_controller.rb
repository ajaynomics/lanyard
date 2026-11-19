# Whose model account a workspace's calls are billed to (docs/billing.md):
# the install's, its own, or another workspace's. Only its owner chooses, and
# only among workspaces they own too, so no workspace is billed for another
# without its owner's choice. Anyone else finds no such workspace.
class Workspaces::PayersController < ApplicationController
  def update
    workspace = Current.user.owned_workspaces.find(params[:workspace_id])
    payer_id = params.expect(workspace: [ :payer_id ])[:payer_id]
    workspace.update!(payer: (Current.user.owned_workspaces.find(payer_id) if payer_id.present?))
    redirect_back_or_to workspace_usage_path(workspace), status: :see_other, notice: "#{workspace} is billed to #{helpers.payer_name(workspace.payer)}."
  end
end
