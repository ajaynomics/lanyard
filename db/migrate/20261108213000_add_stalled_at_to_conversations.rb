class AddStalledAtToConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :stalled_at, :datetime
  end
end
