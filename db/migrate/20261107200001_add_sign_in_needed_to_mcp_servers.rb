class AddSignInNeededToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :sign_in_needed, :boolean, default: false, null: false
  end
end
