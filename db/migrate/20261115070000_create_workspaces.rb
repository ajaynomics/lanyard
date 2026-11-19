# Workspaces (docs/design/workspaces.md): every agent belongs to one. Each
# existing person gets their own, with them its one member, holding all their
# agents. The column stays nullable: the old release, still serving during a
# rolling deploy, makes agents without one, and Agent gives those its person's
# workspace when next saved; a later migration fills any left and makes it
# NOT NULL. Nothing is dropped.
#
# Adding the key makes SQLite rebuild agents, dropping the old table. Inside a
# transaction SQLite ignores Rails' switch turning foreign keys off, so the
# drop emptied core_connectors and connector_moves, whose keys cascade from
# agents (OlderRebuildsMigrationTest). So the migration runs outside one:
# the rebuild in a transaction of its own with foreign keys off, and the fill
# in another, so the fill is still all or nothing.
class CreateWorkspaces < ActiveRecord::Migration[8.2]
  disable_ddl_transaction!

  def up
    transaction do
      create_table :workspaces, &:timestamps

      create_table :workspace_memberships do |t|
        t.references :workspace, null: false, foreign_key: true
        t.references :user, null: false, foreign_key: true
        t.timestamps
        t.index [ :workspace_id, :user_id ], unique: true
      end
    end

    add_reference :agents, :workspace, foreign_key: true

    transaction do
      now = connection.quote(Time.current.utc)
      select_values("SELECT id FROM users ORDER BY id").each do |user_id|
        user_id = Integer(user_id)
        workspace_id = insert("INSERT INTO workspaces (created_at, updated_at) VALUES (#{now}, #{now})")
        execute "INSERT INTO workspace_memberships (workspace_id, user_id, created_at, updated_at) VALUES (#{workspace_id}, #{user_id}, #{now}, #{now})"
        execute "UPDATE agents SET workspace_id = #{workspace_id} WHERE user_id = #{user_id}"
      end
    end
  end

  def down
    remove_reference :agents, :workspace, foreign_key: true
    drop_table :workspace_memberships
    drop_table :workspaces
  end
end
