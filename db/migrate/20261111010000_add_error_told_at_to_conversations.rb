# When a thread last told its person it stopped with an error
# (Conversation::Notifiable#notify_error), so a run that fails again before
# anything goes right is not told again. A run that ends well, or the
# person's next message, clears it.
class AddErrorToldAtToConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :error_told_at, :datetime
  end
end
