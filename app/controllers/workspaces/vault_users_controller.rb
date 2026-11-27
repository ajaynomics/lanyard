# A shared workspace's own Passbolt user, and optionally its own server
# (Workspace::VaultUser), set and removed by its owner. The key and passphrase go in and are never shown
# again; members see only whether there is one (workspaces/_vault_user).
class Workspaces::VaultUsersController < ApplicationController
  include WorkspaceOwnerSettings

  before_action { head :not_found if DurableAssistants::Passbolt.url.blank? }

  def edit
  end

  def update
    @workspace.assign_attributes(passbolt_url: vault_user_params[:url], passbolt_private_key: vault_user_params[:private_key],
      passbolt_passphrase: vault_user_params[:passphrase])
    if @workspace.save(context: :vault_user)
      redirect_to @workspace, status: :see_other, notice: "#{@workspace}'s agents now use its own vault user."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @workspace.forget_vault_user
    redirect_to @workspace, status: :see_other, notice: "#{@workspace}'s agents use the install's vault user again."
  end

  private
    def vault_user_params = params.expect(vault_user: %i[ url private_key passphrase ])
end
