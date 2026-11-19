class AddAsksEveryWriteToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :asks_every_write, :boolean, default: false, null: false
  end
end
