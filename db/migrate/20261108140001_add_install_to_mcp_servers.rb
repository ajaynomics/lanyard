class AddInstallToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :install, :string
  end
end
