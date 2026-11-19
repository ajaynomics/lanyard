module Workspaces
  # A shared workspace's own Campfire, named by its owner alone
  # (docs/campfire.md, "A workspace's own Campfire"): its address and the name
  # of the vault entry its administrator signs in with, never the password.
  # Without one, the install's. For anyone else it is not found.
  class CampfiresController < ApplicationController
    before_action { @workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id]) }

    def update
      if @workspace.update(params.expect(workspace: %i[ campfire_url campfire_vault_entry ]))
        redirect_to @workspace, status: :see_other
      else
        render "workspaces/show", status: :unprocessable_entity
      end
    end

    def destroy
      @workspace.update!(campfire_url: nil, campfire_vault_entry: nil)
      redirect_to @workspace, status: :see_other
    end
  end
end
