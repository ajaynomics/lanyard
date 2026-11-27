class Workspaces::ToolSwitchesController < ApplicationController
  def update
    workspace = Current.user.owned_workspaces.find(params[:workspace_id])
    name, setting, on = params.expect(:tool, :setting, :on)
    raise ActionController::BadRequest unless %w[ 0 1 ].include?(on)

    case setting
    when "disabled_tools"
      raise ActiveRecord::RecordNotFound unless workspace.tool_switch_names.include?(name)
      fixed = workspace.install_tool_off?(name)
    when "asks_every"
      raise ActiveRecord::RecordNotFound unless Tool::AsksEverySend::SETTINGS.key?(name)
      fixed = workspace.install_asks_every?(name)
    else
      raise ActiveRecord::RecordNotFound
    end

    if fixed
      redirect_to workspace, status: :see_other, alert: "This switch is set for this install."
    else
      workspace.with_lock do
        names = workspace.public_send(setting)
        workspace.update!(setting => (on == "1" ? names | [ name ] : names - [ name ]))
      end
      saved(workspace_path(workspace))
    end
  end
end
