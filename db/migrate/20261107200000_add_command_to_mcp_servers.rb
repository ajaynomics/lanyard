# A connector may be pi's `command` entry instead of a `url`: run on the
# agent's own computer (docs/connectors.md).
class AddCommandToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :command, :string
    add_column :mcp_servers, :args, :json, default: [], null: false
    add_column :mcp_servers, :env, :text # encrypted JSON, pi's `env`
    add_column :mcp_servers, :cwd, :string
  end
end
