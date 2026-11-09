# What the agent list shows of each thread: when the person last opened it,
# when the agent last answered them (so a reply since is unread), and the
# tool it is using now. Every thread starts read, so nothing turns unread
# when this deploys.
class AddListStateToConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :read_at, :datetime
    add_column :conversations, :replied_at, :datetime
    add_column :conversations, :current_tool, :string

    up_only do
      execute <<~SQL
        UPDATE conversations SET read_at = CURRENT_TIMESTAMP,
          replied_at = (SELECT MAX(messages.created_at) FROM messages
            WHERE messages.conversation_id = conversations.id AND messages.role = 'assistant')
      SQL
    end
  end
end
