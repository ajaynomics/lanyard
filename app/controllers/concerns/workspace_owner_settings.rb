# What a shared workspace's owner-only settings share: the workspace, found
# only among those the person owns, so for a member, or anyone else, it is not there.
module WorkspaceOwnerSettings
  extend ActiveSupport::Concern

  included do
    before_action { @workspace = Current.user.owned_workspaces.shared.find(params[:workspace_id]) }
  end
end
