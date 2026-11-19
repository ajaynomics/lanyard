module Workspaces
  # A workspace's own name and colour on its people's pages (Brand), set by
  # its owner alone; blank is the install's. Its link host is not among them:
  # only the install's operator sets that, since a host needs the proxy and
  # DNS (docs/deployments.md). For anyone else it is not found.
  class BrandsController < ApplicationController
    before_action { @workspace = Current.user.owned_workspaces.find(params[:workspace_id]) }

    def update
      if @workspace.update(params.expect(workspace: %i[ app_name accent_hue ]))
        redirect_to @workspace, status: :see_other, notice: "#{@workspace} goes by #{@workspace.brand.name}."
      else
        render "workspaces/show", status: :unprocessable_entity
      end
    end
  end
end
