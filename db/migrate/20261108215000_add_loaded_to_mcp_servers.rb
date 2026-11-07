class AddLoadedToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :loaded, :boolean, default: true, null: false
  end
end
