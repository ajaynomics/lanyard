class IndexConversationOpenQueries < ActiveRecord::Migration[8.2]
  def change
    add_index :invocations, [ :state, :expires_at ]
    # Only summaries: an index over every role would tempt SQLite, once it has
    # stats, to sort a long thread's replies instead of walking back by entry.
    add_index :messages, [ :conversation_id, :created_at ], where: "role = 'summary'"
  end
end
