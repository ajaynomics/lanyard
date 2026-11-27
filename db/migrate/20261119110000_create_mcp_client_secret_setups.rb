class CreateMcpClientSecretSetups < ActiveRecord::Migration[8.2]
  def change
    create_table :mcp_client_secret_setups do |t|
      t.references :mcp_server, null: false, foreign_key: { on_delete: :cascade }
      t.references :issued_by, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :token_digest, null: false, index: { unique: true }
      t.string :target_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end
  end
end
