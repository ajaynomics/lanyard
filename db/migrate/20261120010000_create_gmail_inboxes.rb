class CreateGmailInboxes < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_gmail_inboxes do |t|
      t.references :agent, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :mcp_server, null: false, foreign_key: { on_delete: :cascade }
      t.references :enabled_by, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :mailbox, null: false
      t.string :history_id
      t.boolean :enabled, null: false, default: false
      t.string :paused_reason
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    create_table :agent_gmail_inbox_receipts do |t|
      t.references :gmail_inbox, null: false, index: false, foreign_key: { to_table: :agent_gmail_inboxes, on_delete: :cascade }
      t.string :mailbox, null: false
      t.string :gmail_message_id, null: false
      t.index %i[ gmail_inbox_id mailbox gmail_message_id ], unique: true
    end
  end
end
