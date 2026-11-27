class AddToolSwitchesToWorkspaces < ActiveRecord::Migration[8.2]
  def change
    add_column :workspaces, :disabled_tools, :json, default: [], null: false
    add_column :workspaces, :asks_every, :json, default: [], null: false
  end
end
