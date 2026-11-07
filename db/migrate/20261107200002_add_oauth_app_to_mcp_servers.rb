class AddOauthAppToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :oauth_app, :string
  end
end
