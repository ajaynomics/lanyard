module Workspaces
  class AgentSetupsController < ApplicationController
    before_action :set_workspace

    def index
      @setups = visible_setups.order(created_at: :desc, id: :desc)
    end

    def show
      @setup = visible_setups.find(params[:id])
    end

    def new
      @setup = @workspace.agent_setups.new(request_id: SecureRandom.uuid)
    end

    def create
      @setup = @workspace.agent_setups.build(approval.merge(approved_by: Current.user))
      @setup = @setup.record!
      redirect_to workspace_agent_setup_path(@workspace, @setup), status: :see_other
    rescue ActiveRecord::RecordInvalid
      render :new, status: :unprocessable_entity
    rescue Workspace::AgentSetup::Conflict => problem
      @setup.errors.add(:base, problem.message)
      render :new, status: :conflict
    end

    private
      def set_workspace
        scope = %w[ new create ].include?(action_name) ? Current.user.owned_workspaces : Current.user.workspaces
        @workspace = scope.find(params[:workspace_id])
        work_in @workspace
      end

      def visible_setups
        @workspace.owner == Current.user ? @workspace.agent_setups : @workspace.agent_setups.where(operator: Current.user)
      end

      def approval
        params.expect(agent_setup: Workspace::AgentSetup::APPROVAL_FIELDS)
      end
  end
end
