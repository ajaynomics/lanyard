require "test_helper"
require "tmpdir"

class WorkspaceAgentSetupsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261122145000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "the additive migration leaves existing agents and membership roles alone" do
    Dir.mktmpdir("agent-setups-migration") do |dir|
      Scratch.establish_connection(adapter: "sqlite3", database: File.join(dir, "scratch.sqlite3"))
      connection = Scratch.lease_connection
      verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
      migrations = connection.pool.migration_context.migrations
      migrations.select { it.version < VERSION }.each { migrate(connection, it, :up) }
      connection.execute("INSERT INTO users (id, oidc_sub, created_at, updated_at) VALUES (1, 'synthetic', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
      connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Team', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
      connection.execute("INSERT INTO workspace_memberships (workspace_id, user_id, role, created_at, updated_at) VALUES (1, 1, 'owner', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
      connection.execute("INSERT INTO agents (id, workspace_id, user_id, name, email_name, model, instructions, created_at, updated_at) VALUES (1, 1, 1, 'Lead', 'lead', 'test', 'Existing', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
      before = retained_rows(connection)

      migration = migrations.find { it.version == VERSION }
      migrate(connection, migration, :up)
      assert_empty connection.select_rows("SELECT id FROM workspace_agent_setups")
      assert_equal before, retained_rows(connection)
      assert_includes connection.indexes(:workspace_agent_setups).select(&:unique).map(&:columns), %w[ workspace_id request_id ]

      migrate(connection, migration, :down)
      refute connection.table_exists?(:workspace_agent_setups)
      assert_equal before, retained_rows(connection)
    ensure
      ActiveRecord::Migration.verbose = verbose
      Scratch.remove_connection
    end
  end

  private
    def migrate(connection, migration, direction)
      connection.transaction { migration.send(:migration).exec_migration(connection, direction) }
    end

    def retained_rows(connection)
      [ connection.select_rows("SELECT id, workspace_id, user_id, parent_id, instructions FROM agents"),
        connection.select_rows("SELECT workspace_id, user_id, role FROM workspace_memberships") ]
    end
end
