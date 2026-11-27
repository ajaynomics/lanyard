class CreateGmailReplyGrants < ActiveRecord::Migration[8.2]
  def change
    create_table :gmail_reply_grants do |t|
      t.references :mcp_server, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.string :address, null: false
      t.timestamps
      t.index [ :mcp_server_id, :agent_id ], unique: true
    end

    add_column :invocations, :checking_gmail_reply_grant_id, :integer
    add_column :invocations, :gmail_reply_grant_address, :string
  end
end
