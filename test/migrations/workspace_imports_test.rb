require "test_helper"
require "tmpdir"

# 20261117070000 records an install moved in as a workspace. Existing people,
# workspaces and agents are as they were, with nothing imported; a copy
# comes once, and its record goes with its workspace. Run on a database of
# its own built by the migrations before it.
class WorkspaceImportsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261117070000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-imports")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "people, workspaces and agents are as they were, nothing imported, and a copy comes once" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Team', 0, '#{now}', '#{now}'), (2, 'Other', 0, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspace_memberships (workspace_id, user_id, role, created_at, updated_at) VALUES (1, 1, 'owner', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
                        "VALUES (1, 1, 1, 'Scout', 'Hi.', 'made-up/model', 'scout', '#{now}', '#{now}')")
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "Maya" ] ], @connection.select_rows("SELECT id, name FROM users")
    assert_equal [ [ 1, "Team" ], [ 2, "Other" ] ], @connection.select_rows("SELECT id, name FROM workspaces ORDER BY id")
    assert_equal [ [ 1, 1, "Scout" ] ], @connection.select_rows("SELECT id, workspace_id, name FROM agents")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_imports")

    insert = ->(workspace_id) { @connection.execute("INSERT INTO workspace_imports (workspace_id, source_digest, source_version, created_at, updated_at) VALUES (#{workspace_id}, 'abc', '20261115040000', '#{now}', '#{now}')") }
    insert.(1)
    assert_raises(ActiveRecord::RecordNotUnique) { insert.(2) }
    @connection.execute("PRAGMA foreign_keys = ON")
    @connection.execute("DELETE FROM agents")
    @connection.execute("DELETE FROM workspace_memberships")
    @connection.execute("DELETE FROM workspaces WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_imports")
  end

  private
    def run_migrations
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, :up) }
      end
    end
end
