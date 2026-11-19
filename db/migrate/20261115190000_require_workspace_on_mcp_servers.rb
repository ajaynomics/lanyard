# Connectors are reached through their workspace now (docs/design/workspaces.md,
# section 2.4), so each needs one. A connector the release before made without
# one is filled as 20261115160000 filled them: a conversation's in its agent's
# workspace, a person's in their personal one. A name is unique within a
# workspace rather than a person, so the install's connectors can be in each
# of their workspaces. The release before fills the column on every save,
# if it has 20261115160000: an install older than that deploys a release with
# it first, or a connector saved by the old release mid-deploy is refused.
#
# Making the column NOT NULL makes SQLite rebuild mcp_servers, dropping the old table. Inside a
# transaction SQLite ignores Rails' switch turning foreign keys off, so the
# drop emptied core_connectors and connector_moves, whose keys cascade from
# mcp_servers (OlderRebuildsMigrationTest). So the migration runs outside one:
# the rebuild in a transaction of its own with foreign keys off, and the fill
# in another, so the fill is still all or nothing.
class RequireWorkspaceOnMcpServers < ActiveRecord::Migration[8.2]
  disable_ddl_transaction!

  def up
    transaction do
      execute <<~SQL
        UPDATE mcp_servers SET workspace_id = (
          SELECT agents.workspace_id FROM conversations JOIN agents ON agents.id = conversations.agent_id
          WHERE conversations.id = mcp_servers.conversation_id)
        WHERE workspace_id IS NULL AND conversation_id IS NOT NULL
      SQL
      execute <<~SQL
        UPDATE mcp_servers SET workspace_id = (
          SELECT MIN(workspaces.id) FROM workspaces JOIN workspace_memberships ON workspace_memberships.workspace_id = workspaces.id
          WHERE workspace_memberships.user_id = mcp_servers.user_id AND workspaces.personal)
        WHERE workspace_id IS NULL AND conversation_id IS NULL
      SQL
    end
    change_column_null :mcp_servers, :workspace_id, false
    transaction do
      remove_index :mcp_servers, %i[ user_id name ], unique: true, where: "conversation_id IS NULL"
      add_index :mcp_servers, %i[ workspace_id name ], unique: true, where: "conversation_id IS NULL"
    end
  end

  def down
    remove_index :mcp_servers, %i[ workspace_id name ], unique: true, where: "conversation_id IS NULL"
    add_index :mcp_servers, %i[ user_id name ], unique: true, where: "conversation_id IS NULL"
    change_column_null :mcp_servers, :workspace_id, true
  end
end
