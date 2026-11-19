module Workspaces
  # A shared workspace's own voip.ms account, named by its owner alone
  # (docs/phone.md, "A workspace's own voip.ms account"): the name of the vault
  # entry that holds it, never the password. Without one, the install's. For
  # anyone else it is not found.
  class VoipmsAccountsController < ApplicationController
    before_action { @workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id]) }

    def update
      if @workspace.update(params.expect(workspace: %i[ voipms_vault_entry ]))
        redirect_to @workspace, status: :see_other
      else
        render "workspaces/show", status: :unprocessable_entity
      end
    end

    def destroy
      @workspace.update!(voipms_vault_entry: nil)
      redirect_to @workspace, status: :see_other
    end
  end
end
