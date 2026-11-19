# A workspace's connectors and helpers: the page names its workspace in its
# address (/workspaces/:workspace_id/connectors, from a group's menu in the
# agents list), so it shows the workspace the person came from, not whichever
# they used last. One they are not in is not found. A form there names it too.
# An address with none, an old link's, is the one they used last, which the
# page names.
module WorkspaceScoped
  extend ActiveSupport::Concern

  included do
    before_action { work_in Current.user.workspaces.find(params[:workspace_id]) if params[:workspace_id] }
  end
end
