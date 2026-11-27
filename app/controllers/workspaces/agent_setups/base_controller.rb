module Workspaces::AgentSetups
  class BaseController < ApplicationController
    before_action :set_setup

    private
      def set_setup
        @workspace = Current.user.workspaces.find(params[:workspace_id])
        @setup = @workspace.agent_setups.find(params[:agent_setup_id])
      end

      def show_setup(notice)
        redirect_to workspace_agent_setup_path(@workspace, @setup), status: :see_other, notice: notice
      end
  end
end
