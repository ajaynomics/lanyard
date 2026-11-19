# Every agent is in a workspace (docs/design/workspaces.md), and from here it
# must be. The release before this one fills it on save, so only an agent an
# older release made can still be without one: it goes into its person's own
# workspace, which is made for a person who has none yet, as User#workspace
# makes it. Nothing is dropped.
#
# Making the column NOT NULL makes SQLite rebuild agents, dropping the old table. Inside a
# transaction SQLite ignores Rails' switch turning foreign keys off, so the
# drop emptied core_connectors and connector_moves, whose keys cascade from
# agents (OlderRebuildsMigrationTest). So the migration runs outside one:
# the rebuild in a transaction of its own with foreign keys off, and the fill
# in another, so the fill is still all or nothing.
class RequireAgentWorkspaces < ActiveRecord::Migration[8.2]
  disable_ddl_transaction!

  def up
    transaction do
      now = connection.quote(Time.current.utc)
      select_values("SELECT DISTINCT user_id FROM agents WHERE workspace_id IS NULL ORDER BY user_id").each do |user_id|
        user_id = Integer(user_id)
        workspace_id = select_value("SELECT MIN(workspace_id) FROM workspace_memberships WHERE user_id = #{user_id}") || begin
          insert("INSERT INTO workspaces (created_at, updated_at) VALUES (#{now}, #{now})").tap do
            execute "INSERT INTO workspace_memberships (workspace_id, user_id, created_at, updated_at) VALUES (#{it}, #{user_id}, #{now}, #{now})"
          end
        end
        execute "UPDATE agents SET workspace_id = #{Integer(workspace_id)} WHERE user_id = #{user_id} AND workspace_id IS NULL"
      end
    end

    change_column_null :agents, :workspace_id, false
  end

  def down
    change_column_null :agents, :workspace_id, true
  end
end
