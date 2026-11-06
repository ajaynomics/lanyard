class AddParentToConversations < ActiveRecord::Migration[8.2]
  def change
    add_reference :conversations, :parent, foreign_key: { to_table: :conversations, on_delete: :nullify }
    add_column :conversations, :forked_at_entry_id, :integer
  end
end
