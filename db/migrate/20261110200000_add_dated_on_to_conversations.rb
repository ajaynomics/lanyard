# The day, in the agent's zone, its thread was last told the date
# (Conversation#date_note). Kept here, not read back from the messages, since a
# message queued behind a busy agent is not in them yet. A summary clears it.
class AddDatedOnToConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :dated_on, :date
  end
end
