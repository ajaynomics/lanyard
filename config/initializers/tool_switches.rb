Rails.application.config.to_prepare do
  Workspace::ToolSwitches.validate_install!
end
