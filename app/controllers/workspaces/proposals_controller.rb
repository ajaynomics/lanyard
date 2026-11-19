# A member proposes new shared instructions for the workspace, for its owner
# to accept (Proposals::AcceptancesController) or decline; its proposer may
# withdraw it.
class Workspaces::ProposalsController < ApplicationController
  before_action :set_workspace

  def create
    @proposal = @workspace.proposals.new(params.expect(proposal: [ :instructions ]).merge(proposed_by: Current.user))
    if @proposal.save
      redirect_to @workspace, status: :see_other, notice: "Proposed. #{@workspace.owner} decides."
    else
      render "workspaces/show", status: :unprocessable_entity
    end
  end

  def destroy
    proposal = @workspace.proposals.find(params[:id])
    return head :forbidden unless proposal.withdrawable_by?(Current.user)

    proposal.destroy!
    redirect_to @workspace, status: :see_other
  end

  private
    def set_workspace
      @workspace = Current.user.workspaces.shared.find(params[:workspace_id])
    end
end
