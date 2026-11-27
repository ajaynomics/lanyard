# A person reviews an approved instruction revision's exact difference from
# the current text, then restores it as a new revision (InstructionRestoration).
class InstructionRestorationsController < ApplicationController
  before_action :set_target
  before_action :no_store

  def index
    before = Integer(params[:before].to_s, exception: false)
    @revisions = @restoration.revision_page(before: before, limit: 26)
    if @revisions.size == 26
      @revisions.pop
      @next_before = @revisions.last.first
    end
  end

  def new
    @preview = @restoration.preview(params[:instruction_revision_id])
  end

  def create
    @restoration.restore!(params[:instruction_revision_id], token: params[:review_token])
    redirect_to @instructions_path, status: :see_other, notice: "Restored as a new revision. It applies from the next message."
  rescue InstructionRestoration::Stale, ActiveRecord::RecordInvalid
    render :stale, status: :conflict
  end

  private
    def set_target
      if params[:agent_id]
        @agent = find_in_workspace(:agents, params[:agent_id])
        @target = @agent
        @history_path = agent_instruction_revisions_path(@agent)
        @instructions_path = agent_instructions_path(@agent)
      else
        @target = Current.user.owned_workspaces.find(params[:workspace_id])
        work_in @target
        @history_path = workspace_instruction_revisions_path(@target)
        @instructions_path = workspace_path(@target, anchor: ("workspace_instructions" unless @target.personal?))
      end
      @restoration = InstructionRestoration.new(target: @target, workspace: Current.workspace, by: Current.user)
    end
end
