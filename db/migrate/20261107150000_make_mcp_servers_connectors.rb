# MCP servers become connectors (docs/design/PARITY.md, Round 6): a person's
# own, for all their agents, or one agent's (conversation_id), with the sign-in
# kept beside them. The bot level goes: each existing server becomes its bot
# owner's connector for all their agents. bot_id is emptied and ignored here,
# and dropped in a later migration, so a rolling deploy never reads a missing
# column.
class MakeMcpServersConnectors < ActiveRecord::Migration[8.2]
  def up
    add_reference :mcp_servers, :user, foreign_key: true
    add_reference :mcp_servers, :conversation, foreign_key: true
    add_column :mcp_servers, :enabled, :boolean, default: true, null: false
    add_column :mcp_servers, :headers, :text # encrypted JSON, pi's `headers`
    add_column :mcp_servers, :oauth_scope, :string # pi's `oauth.scope`
    add_column :mcp_servers, :oauth_client, :text
    add_column :mcp_servers, :oauth_tokens, :text
    add_column :mcp_servers, :oauth_pending, :text
    add_column :mcp_servers, :oauth_state, :string
    add_index :mcp_servers, :oauth_state, unique: true

    execute "UPDATE mcp_servers SET user_id = (SELECT user_id FROM bots WHERE bots.id = mcp_servers.bot_id)"
    # Two bots of one person may both have had a server called "wiki"; names are now one per person.
    execute <<~SQL
      UPDATE mcp_servers SET name = substr(name, 1, 12) || '_' || id
      WHERE id NOT IN (SELECT MIN(id) FROM mcp_servers GROUP BY user_id, name)
    SQL
    execute "UPDATE mcp_servers SET bot_id = NULL"

    remove_index :mcp_servers, %i[ bot_id name ]
    change_column_null :mcp_servers, :bot_id, true
    change_column_null :mcp_servers, :user_id, false
    change_column_null :mcp_servers, :url, true # an agent's switch-off names a server; it has no address
    add_index :mcp_servers, %i[ user_id name ], unique: true, where: "conversation_id IS NULL"
    add_index :mcp_servers, %i[ conversation_id name ], unique: true, where: "conversation_id IS NOT NULL"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
