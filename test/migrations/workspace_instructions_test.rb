require "test_helper"
require "tmpdir"

# 20261117040000 gives a workspace shared instructions, kept revisions of them
# and members' proposals. Existing workspaces have none, so their agents read
# what they read before; deleting a workspace takes its revisions and
# proposals, and deleting a person or an agent keeps a revision, forgetting
# only who. Run on a database of its own built by the migrations before it.
class WorkspaceInstructionsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261117040000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-instructions")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    @connection.execute("PRAGMA foreign_keys = ON")
    run_migrations { it < VERSION }
    @now = Time.current.utc.iso8601
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing workspaces have empty shared instructions; revisions and proposals go with their workspace, and keep their revision without the person" do
    sql "INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's1', 'Maya', 'maya@example.com', '#{@now}', '#{@now}'), (2, 's2', 'Robin', 'robin@example.com', '#{@now}', '#{@now}')"
    sql "INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Team', 0, '#{@now}', '#{@now}'), (2, NULL, 1, '#{@now}', '#{@now}')"
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "Team", "" ], [ 2, nil, "" ] ], @connection.select_rows("SELECT id, name, instructions FROM workspaces ORDER BY id")

    sql "INSERT INTO workspace_revisions (workspace_id, instructions, changed_by_id, proposed_by_id, created_at) VALUES (1, 'Be kind.', 1, 2, '#{@now}')"
    sql "INSERT INTO workspace_proposals (workspace_id, proposed_by_id, instructions, created_at, updated_at) VALUES (1, 2, 'Be brief.', '#{@now}', '#{@now}')"
    sql "DELETE FROM users WHERE id = 2"
    assert_equal [ [ "Be kind.", 1, nil ] ], @connection.select_rows("SELECT instructions, changed_by_id, proposed_by_id FROM workspace_revisions")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_proposals")

    sql "DELETE FROM workspaces WHERE id = 1"
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_revisions")
  end

  private
    def sql(statement) = @connection.execute(statement)

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
