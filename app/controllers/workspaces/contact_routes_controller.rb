# The owner of a shared workspace routes an outside contact to one of its
# agents, which then answers their mail and texts (Workspace::ContactRoute),
# and removes a route. Anyone else finds no such workspace.
class Workspaces::ContactRoutesController < ApplicationController
  before_action :set_workspace

  def create
    @contact_route = Workspace::ContactRoute.new(workspace: @workspace, contact: contact_route_params[:contact],
      agent: @workspace.agents.find_by(id: contact_route_params[:agent_id]))
    if @contact_route.save
      redirect_to @workspace, status: :see_other, notice: "#{@contact_route} goes to #{@contact_route.agent}."
    else
      render "workspaces/show", status: :unprocessable_entity
    end
  end

  def destroy
    @workspace.contact_routes.find(params[:id]).destroy!
    redirect_to @workspace, status: :see_other
  end

  private
    def set_workspace
      @workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id])
    end

    def contact_route_params = params.expect(contact_route: [ :contact, :agent_id ])
end
