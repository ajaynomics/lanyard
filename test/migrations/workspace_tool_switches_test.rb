require "test_helper"
require "tmpdir"

class WorkspaceToolSwitchesMigrationTest < ActiveSupport::TestCase
  VERSION = 20261119160000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "existing workspace rows and inserts from the old app receive empty lists" do
    Dir.mktmpdir("workspace-tool-switches") do |dir|
      Scratch.establish_connection(adapter: "sqlite3", database: File.join(dir, "scratch.sqlite3"))
      connection = Scratch.lease_connection
      verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
      migrate(connection) { it < VERSION }
      insert(connection, 1, "Orchard")
      migrate(connection) { it == VERSION }
      insert(connection, 2, "Late arrival")

      assert_equal [ [ "Orchard", "[]", "[]" ], [ "Late arrival", "[]", "[]" ] ],
        connection.select_rows("SELECT name, disabled_tools, asks_every FROM workspaces ORDER BY id")
      %w[ disabled_tools asks_every ].each do |column|
        assert_raises(ActiveRecord::NotNullViolation) { connection.execute("UPDATE workspaces SET #{column} = NULL WHERE id = 1") }
      end
    ensure
      ActiveRecord::Migration.verbose = verbose
      Scratch.remove_connection
    end
  end

  private
    # Bind each migration to the scratch database, not the application's primary connection.
    def migrate(connection)
      connection.pool.migration_context.migrations.each do |migration|
        next unless yield migration.version
        connection.transaction { migration.send(:migration).exec_migration(connection, :up) }
      end
    end

    def insert(connection, id, name)
      connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (#{id}, #{connection.quote(name)}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
    end
end
