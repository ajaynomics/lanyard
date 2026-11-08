# A connector's tools the person turned off for every agent that uses it, by
# the names the server lists them under.
class AddDisabledToolsToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :disabled_tools, :json, default: [], null: false
  end
end
