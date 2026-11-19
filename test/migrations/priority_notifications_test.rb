require "test_helper"
require "tmpdir"

# 20261118120000 adds whether an agent's cards reach the person as priority
# notifications (#82). Every agent, those made before it too, keeps sounding
# as before; the column never holds NULL, and code from before it (a rollback
# image) can still add agents, as the default fills it in (on). Run on a
# database of its own built by the migrations before it, then it alone, and
# then back down.
class PriorityNotificationsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261118120000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("priority-notifications")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    insert_agent(1, "Iris")
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing agents keep priority, an insert that does not name it gets priority, and it is never NULL" do
    run_migrations(:up) { it == VERSION }
    insert_agent(2, "Rowan")

    assert_equal [ [ 1, 1 ], [ 2, 1 ] ], @connection.select_rows("SELECT id, priority_notifications FROM agents ORDER BY id")
    assert_raises(ActiveRecord::NotNullViolation) { @connection.execute("UPDATE agents SET priority_notifications = NULL WHERE id = 1") }
  end

  test "it goes back down, keeping the agents" do
    run_migrations(:up) { it == VERSION }
    run_migrations(:down) { it == VERSION }

    assert_not_includes @connection.columns(:agents).map(&:name), "priority_notifications"
    assert_equal [ [ 1, "Iris" ] ], @connection.select_rows("SELECT id, name FROM agents")
  end

  private
    def insert_agent(id, name)
      now = Time.current.utc.iso8601
      @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (#{id}, 1, 1, '#{name}', 'Help.', 'example/model', 'agent-#{id}', '#{now}', '#{now}')")
    end

    def run_migrations(direction)
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, direction) }
      end
    end
end
