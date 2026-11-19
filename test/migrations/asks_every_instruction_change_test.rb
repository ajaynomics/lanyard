require "test_helper"
require "tmpdir"

# 20261116190000 adds the Permissions switch that makes change_yourself ask
# before every change. It is on for every agent, those made before it too,
# the column never holds NULL, and code from before it (a rollback image) can
# still add agents, as the default fills it in (on). Run on a database of its own
# built by the migrations before it, then it alone, and then back down.
class AsksEveryInstructionChangeMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116190000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("asks-every-instruction-change")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    insert_agent(1, "Iris")
    @connection.execute("UPDATE agents SET asks_every_email = 1 WHERE id = 1")
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing agents get it on, an insert that does not name it gets on, and it is never NULL" do
    run_migrations(:up) { it == VERSION }
    insert_agent(2, "Rowan")

    assert_equal [ [ 1, 1, 1 ], [ 2, 1, 0 ] ],
      @connection.select_rows("SELECT id, asks_every_instruction_change, asks_every_email FROM agents ORDER BY id")
    assert_raises(ActiveRecord::NotNullViolation) { @connection.execute("UPDATE agents SET asks_every_instruction_change = NULL WHERE id = 1") }
    @connection.execute("UPDATE agents SET asks_every_instruction_change = 0 WHERE id = 1")
    assert_equal [ 0, 1 ], @connection.select_values("SELECT asks_every_instruction_change FROM agents ORDER BY id")
  end

  test "it goes back down, keeping the agents" do
    run_migrations(:up) { it == VERSION }
    run_migrations(:down) { it == VERSION }

    assert_not_includes @connection.columns(:agents).map(&:name), "asks_every_instruction_change"
    assert_equal [ [ 1, "Iris", 1 ] ], @connection.select_rows("SELECT id, name, asks_every_email FROM agents")
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
