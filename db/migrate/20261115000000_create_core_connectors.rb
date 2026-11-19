# A person's connectors become core or lookup for each agent, not for all of
# them at once (docs/connectors.md). Every agent keeps, as core, each of its
# person's connectors that was loaded before, so no agent's tools change at
# deploy: switched-off ones too, so switching one on again brings it back as
# it was. mcp_servers.loaded stays for the release still running; only a
# conversation's own connector reads it now.
class CreateCoreConnectors < ActiveRecord::Migration[8.2]
  def up
    create_table :core_connectors do |t|
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :mcp_server, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :created_at, null: false
      t.index %i[ agent_id mcp_server_id ], unique: true
    end

    create_table :connector_moves do |t|
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.references :mcp_server, foreign_key: { on_delete: :nullify }
      t.string :connector_name, null: false
      t.string :reason, null: false
      t.datetime :created_at, null: false
    end

    add_column :agents, :promotes_found_tools, :boolean, default: false, null: false
    # The install's word last applied to an office connector; none yet for
    # those made before, so deploying makes none newly core (McpServer.install_for).
    add_column :mcp_servers, :install_core, :boolean

    execute <<~SQL
      INSERT INTO core_connectors (agent_id, mcp_server_id, created_at)
      SELECT agents.id, mcp_servers.id, CURRENT_TIMESTAMP
      FROM agents JOIN mcp_servers ON mcp_servers.user_id = agents.user_id
      WHERE mcp_servers.conversation_id IS NULL AND mcp_servers.loaded = 1
    SQL

    # An agent that already keeps tools it found goes on keeping them, so
    # nothing it declares changes at deploy; its person can switch it off.
    execute <<~SQL
      UPDATE agents SET promotes_found_tools = 1
      WHERE id IN (SELECT agent_id FROM conversations WHERE json_array_length(activated_tools) > 0)
    SQL
  end

  def down
    remove_column :mcp_servers, :install_core
    remove_column :agents, :promotes_found_tools
    drop_table :connector_moves
    drop_table :core_connectors
  end
end
