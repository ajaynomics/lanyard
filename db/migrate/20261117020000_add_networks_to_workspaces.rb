# A workspace's own place on its agents' networks (docs/design/workspaces.md,
# 2.1, 2.3 and 3): its Concourse home network and its own Campfire, none at
# first, so every workspace goes on as before; an identity outside the home
# network is a bridge, which speaks once the workspace's owner approves it;
# and a Campfire room's loop hold is a workspace's, not a person's.
#
# Every identity already joined is marked an approved bridge, its approver the
# owner of its agent's workspace, so whichever home network an owner names
# later, nothing live stops. Room holds go to a new table, keyed by
# workspace, each person's copied into their personal workspace, where their
# agents were; the release before still reads and writes its own table, which
# stays until a later release drops it, and now goes when its person does.
class AddNetworksToWorkspaces < ActiveRecord::Migration[8.2]
  def up
    add_column :workspaces, :concourse_home, :string
    add_column :workspaces, :campfire_url, :string
    add_column :workspaces, :campfire_vault_entry, :string

    add_reference :concourse_agents, :bridge_approved_by, foreign_key: { to_table: :users, on_delete: :nullify }
    add_column :concourse_agents, :bridge_approved_at, :datetime
    execute <<~SQL
      UPDATE concourse_agents SET bridge_approved_at = CURRENT_TIMESTAMP,
        bridge_approved_by_id = (SELECT workspace_memberships.user_id FROM agents
          JOIN workspace_memberships ON workspace_memberships.workspace_id = agents.workspace_id AND workspace_memberships.role = 'owner'
          WHERE agents.id = concourse_agents.agent_id)
    SQL

    create_table :workspace_campfire_rooms do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :room_id, null: false
      t.datetime :held_at
      t.json :relayed_at, null: false, default: []
      t.timestamps
      t.index %i[ workspace_id room_id ], unique: true
    end
    execute <<~SQL
      INSERT INTO workspace_campfire_rooms (workspace_id, room_id, held_at, relayed_at, created_at, updated_at)
        SELECT workspace_memberships.workspace_id, campfire_rooms.room_id, campfire_rooms.held_at, campfire_rooms.relayed_at,
          campfire_rooms.created_at, campfire_rooms.updated_at
        FROM campfire_rooms
        JOIN workspace_memberships ON workspace_memberships.user_id = campfire_rooms.user_id
        JOIN workspaces ON workspaces.id = workspace_memberships.workspace_id AND workspaces.personal
    SQL
    remove_foreign_key :campfire_rooms, :users
    add_foreign_key :campfire_rooms, :users, on_delete: :cascade
  end

  def down
    remove_foreign_key :campfire_rooms, :users
    add_foreign_key :campfire_rooms, :users
    drop_table :workspace_campfire_rooms
    remove_column :concourse_agents, :bridge_approved_at
    remove_reference :concourse_agents, :bridge_approved_by, foreign_key: { to_table: :users }
    remove_column :workspaces, :campfire_vault_entry
    remove_column :workspaces, :campfire_url
    remove_column :workspaces, :concourse_home
  end
end
