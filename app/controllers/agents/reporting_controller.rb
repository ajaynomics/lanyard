module Agents
  class ReportingController < ApplicationController
    before_action :set_agent

    def edit
    end

    def update
      value = params.expect(reporting: [ :parent_id ]).fetch(:parent_id).to_s
      raise ActionController::BadRequest unless value.empty? || value.match?(/\A[1-9]\d*\z/)

      moved = @agent.with_lock do
        next false unless @agent.workspace_id == Current.workspace.id && @agent.owned_by?(Current.user)
        @agent.update(parent_id: value.presence)
      end

      if moved
        manager = @agent.manager
        @notice = manager ? "#{@agent} now reports to #{manager}." : "#{@agent} is now at the top level."
        respond_to do |format|
          format.turbo_stream
          format.html { redirect_to conversations_path, status: :see_other, notice: @notice }
        end
      elsif @agent.errors.any?
        @agent.parent_id = @agent.parent_id_in_database
        render :edit, formats: [ :html ], status: :unprocessable_entity
      else
        head :not_found
      end
    end

    private
      def set_agent
        @agent = find_in_workspace(:agents, params[:agent_id])
        head :not_found unless @agent.owned_by?(Current.user)
      end
  end
end
