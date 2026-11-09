# The agent list sorts by the last news for the person (Conversation::Standing):
# until something new happens, that is the thread's last activity.
class AddListedAtToConversations < ActiveRecord::Migration[8.2]
  def up
    add_column :conversations, :listed_at, :datetime
    execute "UPDATE conversations SET listed_at = COALESCE(last_message_at, created_at)"
    change_column_null :conversations, :listed_at, false
    add_index :conversations, [ :user_id, :listed_at ]
  end

  def down
    remove_column :conversations, :listed_at
  end
end
