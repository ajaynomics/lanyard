# Connectors belong to the workspace (docs/design/workspaces.md, section 2.4).
# This only records which: a conversation's connector is in its agent's
# workspace, a person's in their personal one. They are still reached through
# their person; moving that is its own step. Nullable: the release before this
# one makes connectors without it, and McpServer fills it on save.
#
# Adding the key makes SQLite rebuild mcp_servers, dropping the old table. Inside a
# transaction SQLite ignores Rails' switch turning foreign keys off, so the
# drop emptied core_connectors and connector_moves, whose keys cascade from
# mcp_servers (OlderRebuildsMigrationTest). So the migration runs outside one:
# the rebuild in a transaction of its own with foreign keys off, and the fill
# in another, so the fill is still all or nothing.
class AddWorkspaceToMcpServers < ActiveRecord::Migration[8.2]
  disable_ddl_transaction!

  def up
    add_reference :mcp_servers, :workspace, foreign_key: true

    transaction do
      execute <<~SQL
        UPDATE mcp_servers SET workspace_id = (
          SELECT agents.workspace_id FROM conversations JOIN agents ON agents.id = conversations.agent_id
          WHERE conversations.id = mcp_servers.conversation_id)
        WHERE conversation_id IS NOT NULL
      SQL
      execute <<~SQL
        UPDATE mcp_servers SET workspace_id = (
          SELECT MIN(workspaces.id) FROM workspaces JOIN workspace_memberships ON workspace_memberships.workspace_id = workspaces.id
          WHERE workspace_memberships.user_id = mcp_servers.user_id AND workspaces.personal)
        WHERE conversation_id IS NULL
      SQL
    end
  end

  def down
    remove_reference :mcp_servers, :workspace, foreign_key: true
  end
end
