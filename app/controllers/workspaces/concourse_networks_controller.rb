module Workspaces
  # A shared workspace's Concourse home network, named by its owner alone
  # (docs/design/workspaces.md, 2.3): its agents' joins there are ordinary,
  # anywhere else a bridge the owner approves (ConcourseAgent::Bridge). For
  # anyone else it is not found.
  class ConcourseNetworksController < ApplicationController
    before_action { @workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id]) }

    def update
      if @workspace.name_concourse_home(params.expect(workspace: [ :concourse_home ])[:concourse_home], by: Current.user)
        ahoy.track "Concourse home network named", workspace_id: @workspace.id
        redirect_to @workspace, status: :see_other
      else
        render "workspaces/show", status: :unprocessable_entity
      end
    end
  end
end
