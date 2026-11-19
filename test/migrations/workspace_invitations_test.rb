require "test_helper"
require "tmpdir"

# 20261115170000 adds invitations to a workspace. Existing people and their
# workspaces are as they were, with none pending; an email is invited to a
# workspace once. Run on a database of its own built by the migrations before it.
class WorkspaceInvitationsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261115170000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-invitations")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "people and workspaces are as they were, none invited, and an email is invited to a workspace once" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Team', 0, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspace_memberships (workspace_id, user_id, role, created_at, updated_at) VALUES (1, 1, 'owner', '#{now}', '#{now}')")
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "Maya" ] ], @connection.select_rows("SELECT id, name FROM users")
    assert_equal [ [ 1, 1, "owner" ] ], @connection.select_rows("SELECT workspace_id, user_id, role FROM workspace_memberships")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_invitations")

    insert = -> { @connection.execute("INSERT INTO workspace_invitations (workspace_id, inviter_id, email, created_at, updated_at) VALUES (1, 1, 'guest@example.com', '#{now}', '#{now}')") }
    insert.()
    assert_raises(ActiveRecord::RecordNotUnique) { insert.() }
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
