# Every column is nullable or defaulted and every backfill is SQL, so the
# release before this one keeps running while the migration lands.
class AddListingToConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :archived_at, :datetime
    add_column :conversations, :last_message_at, :datetime
    add_reference :conversations, :root, foreign_key: { to_table: :conversations, on_delete: :nullify }
    add_column :conversations, :branches_count, :integer, default: 0, null: false
    add_index :conversations, %i[ bot_id archived_at last_message_at ], name: "index_conversations_for_listing"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE conversations SET last_message_at = COALESCE(
            (SELECT MAX(messages.created_at) FROM messages WHERE messages.conversation_id = conversations.id),
            conversations.created_at)
        SQL
        # A branch's root is the conversation at the top of its parent chain.
        execute <<~SQL
          WITH RECURSIVE family(id, root) AS (
            SELECT id, id FROM conversations WHERE parent_id IS NULL
            UNION ALL
            SELECT conversations.id, family.root FROM conversations JOIN family ON conversations.parent_id = family.id
          )
          UPDATE conversations SET root_id = (SELECT root FROM family WHERE family.id = conversations.id)
          WHERE parent_id IS NOT NULL
        SQL
        execute <<~SQL
          UPDATE conversations SET branches_count =
            (SELECT COUNT(*) FROM conversations AS branches WHERE branches.parent_id = conversations.id)
        SQL
      end
    end
  end
end
