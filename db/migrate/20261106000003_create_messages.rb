# Rails' rebuildable copy of each conversation's committed transcript, for
# the screens. The sidecar's store stays canonical for the model; this copy is
# filled by cursor pulls, never read back, and rebuilt by Conversation#resync!.
class CreateMessages < ActiveRecord::Migration[8.2]
  def change
    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :entry_key, null: false
      t.integer :entry_id, null: false
      t.string :role, null: false
      t.text :content, null: false, default: ""
      t.string :tool_name
      t.string :tool_call_id
      t.json :tool_calls, null: false, default: []
      t.boolean :error, null: false, default: false
      t.datetime :created_at, null: false
    end
    add_index :messages, [ :conversation_id, :entry_key ], unique: true

    add_column :conversations, :last_entry_id, :integer
    add_column :conversations, :failure, :string
  end
end
