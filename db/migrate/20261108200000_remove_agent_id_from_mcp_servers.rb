# Ignored since the rename to Agent and emptied before it, yet rows restored
# from an older backup still carry it, and its foreign key then stops their
# agent from being deleted. A connector belongs to a conversation or its user.
class RemoveAgentIdFromMcpServers < ActiveRecord::Migration[8.2]
  def change
    remove_foreign_key :mcp_servers, :agents
    remove_index :mcp_servers, :agent_id
    remove_column :mcp_servers, :agent_id, :integer
  end
end
