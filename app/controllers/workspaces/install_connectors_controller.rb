# A workspace's own address and key for one of the install's connectors
# (Workspace::InstallConnector), named by the connector, set and removed by its
# owner. The key goes in and is never shown again; members see only whether
# there is one (workspaces/_install_connectors).
class Workspaces::InstallConnectorsController < ApplicationController
  # A personal workspace too: one the install's owner doesn't own has no key
  # for an office connector until its person gives it one (#168). Found only
  # among the workspaces the person owns, so for anyone else it is not there.
  before_action { @workspace = Current.user.owned_workspaces.find(params[:workspace_id]) }
  before_action :set_install_connector

  def edit
  end

  # A blank key keeps the one saved, so the address can change alone; a blank address is the install's.
  def update
    changes = install_connector_params
    if @install_connector.update(changes[:api_key].blank? ? changes.except(:api_key) : changes)
      redirect_to @workspace, status: :see_other, notice: "#{@workspace}'s #{@install_connector.name} now uses its own key."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @install_connector.destroy! if @install_connector.persisted?
    redirect_to @workspace, status: :see_other, notice: "#{@workspace}'s #{@install_connector.name} no longer has its own key."
  end

  private
    def set_install_connector
      raise ActiveRecord::RecordNotFound unless McpServer.install_entries.key?(params[:id])
      @install_connector = @workspace.install_connectors.find_or_initialize_by(name: params[:id])
    end

    def install_connector_params = params.expect(install_connector: %i[ url api_key ])
end
