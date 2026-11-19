# Existing writers keep working during a rolling deploy. Only new writers
# create prepared envelopes; an old in-flight ID may still conflict honestly.
class CreateConversationSubmissions < ActiveRecord::Migration[8.2]
  def change
    create_table :conversation_submissions do |t|
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.string :request_id, null: false
      t.string :input_digest, null: false
      t.string :payload_digest, null: false
      t.string :definition_digest, null: false
      t.text :payload
      t.json :context, null: false, default: {}
      t.string :durable_id
      t.json :receipt
      t.datetime :accepted_at
      t.datetime :acknowledged_at
      t.datetime :compacted_at
      t.timestamps
      t.index [ :conversation_id, :request_id ], unique: true
    end

    # The ordinary HTML fallback stages a failed draft like a phone share;
    # keeping its original ID prevents a redirect from disguising a conflict.
    add_column :shares, :submission_request_id, :string
  end
end
