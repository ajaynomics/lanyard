require "test_helper"
require "tmpdir"

# 20261117030000 takes the "Always" of people no longer in the agent's
# workspace, given before removal took it itself. Members' grants, and
# everything else, stay as they were. Run on a database of its own built by
# the migrations before it.
class RevokePermissionsOfPeopleWhoLeftMigrationTest < ActiveSupport::TestCase
  VERSION = 20261117030000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("revoke-permissions")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a grant by someone who left the agent's workspace goes; a member's, in a personal or a shared one, stays" do
    now = Time.current.utc.iso8601
    insert = ->(table, values) { @connection.execute("INSERT INTO #{table} #{values}") }
    insert.("users", "(id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 'a', 'Maya', 'maya@example.com', '#{now}', '#{now}'), (2, 'b', 'Theo', 'theo@example.com', '#{now}', '#{now}')")
    insert.("workspaces", "(id, name, personal, created_at, updated_at) VALUES (1, NULL, 1, '#{now}', '#{now}'), (2, NULL, 1, '#{now}', '#{now}'), (3, 'Team', 0, '#{now}', '#{now}')")
    insert.("workspace_memberships", "(workspace_id, user_id, role, created_at, updated_at) VALUES (1, 1, 'owner', '#{now}', '#{now}'), (2, 2, 'owner', '#{now}', '#{now}'), (3, 1, 'owner', '#{now}', '#{now}')")
    insert.("agents", "(id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) VALUES (1, 1, 1, 'Own', 'Help.', 'm', 'own', '#{now}', '#{now}'), (2, 1, 3, 'Team', 'Help.', 'm', 'team', '#{now}', '#{now}')")
    insert.("permissions", "(id, agent_id, tool_name, recipient, granted_by_id, created_at, updated_at) VALUES " \
      "(1, 1, 'send_email', '', 1, '#{now}', '#{now}'), (2, 2, 'send_email', '', 1, '#{now}', '#{now}'), (3, 2, 'send_email', 'x@example.com', 2, '#{now}', '#{now}')")

    run_migrations { it == VERSION }

    assert_equal [ 1, 2 ], @connection.select_values("SELECT id FROM permissions ORDER BY id")
    assert_equal 2, @connection.select_value("SELECT COUNT(*) FROM agents")
    assert_equal 3, @connection.select_value("SELECT COUNT(*) FROM workspace_memberships")
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
