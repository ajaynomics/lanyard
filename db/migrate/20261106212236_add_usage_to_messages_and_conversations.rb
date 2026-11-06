class AddUsageToMessagesAndConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :messages, :usage, :json
    add_column :conversations, :usage, :json
  end
end
