class CreateMcpServers < ActiveRecord::Migration[8.2]
  def change
    create_table :mcp_servers do |t|
      t.references :bot, null: false, foreign_key: true
      t.string :name, null: false
      t.string :url, null: false
      t.text :token
      t.json :tools, null: false, default: []
      t.datetime :refreshed_at
      t.string :refresh_error
      t.timestamps
    end
    add_index :mcp_servers, %i[ bot_id name ], unique: true
  end
end
