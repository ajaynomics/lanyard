# Serves a transcript's order and the tree's fork points.
class AddConversationEntryIndexToMessages < ActiveRecord::Migration[8.2]
  def change
    add_index :messages, %i[ conversation_id entry_id ]
  end
end
