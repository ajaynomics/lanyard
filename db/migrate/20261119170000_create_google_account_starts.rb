class CreateGoogleAccountStarts < ActiveRecord::Migration[8.2]
  def change
    create_table :google_account_starts do |t|
      t.references :mcp_server, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :issued_by, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :issued_email, null: false
      t.string :expected_email_digest, null: false
      t.string :target_digest, null: false
      t.string :token_digest, null: false, index: { unique: true }
      t.string :state_digest, index: { unique: true }
      t.string :browser_digest
      t.datetime :expires_at, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
  end
end
