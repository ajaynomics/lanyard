class AddGmailGrantToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :gmail_grant, :text
  end
end
