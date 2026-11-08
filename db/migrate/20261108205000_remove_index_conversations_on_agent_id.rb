# Three indexes already begin with agent_id, so this one only slowed writes.
class RemoveIndexConversationsOnAgentId < ActiveRecord::Migration[8.2]
  def change
    remove_index :conversations, :agent_id, name: "index_conversations_on_agent_id"
  end
end
