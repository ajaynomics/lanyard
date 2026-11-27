# Workspaces (docs/design/workspaces.md): Settings lists the person's, their
# own first. A person makes a shared one, named, and owns it. Each has its
# page, their personal one too, where a member renames it: a personal one's
# name, until given, is its person's. Anyone not in it finds no such workspace.
class WorkspacesController < ApplicationController
  layout "settings", only: :index
  before_action :set_workspace, only: %i[ show edit update ]

  def index
    @workspaces = Current.user.workspaces.personal_first.includes(:memberships)
  end

  # Its page is a place in it: New agent starts there next.
  def show
    work_in @workspace
  end

  def new
    @workspace = Workspace.new
  end

  # Its maker owns it, and works in it from now on: the agents they make next are its.
  def create
    @workspace = Workspace.make(name: workspace_params[:name], owner: Current.user)
    if @workspace.persisted?
      session[:workspace_id] = @workspace.id
      redirect_to @workspace, status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    attributes = workspace_params
    if attributes.key?(:own_instruction_approval) && !Current.admin?
      raise ActiveRecord::RecordNotFound
    end
    attributes[:name] = attributes[:name].presence if attributes.key?(:name)
    if @workspace.update(attributes)
      redirect_to @workspace, status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_workspace
      @workspace = Current.user.workspaces.find(params[:id])
    end

    def workspace_params = params.expect(workspace: [ :name, :own_instruction_approval ])
end
