require "test_helper"
require "tmpdir"

# 20261118140000 records the model and thinking a helper ran on, and those a
# workflow's step asked for: four empty columns, so every existing helper and
# step is as it was and reads as having run on its agent's own. Code from
# before writes them without knowing the columns; it goes back down cleanly.
# Run on a database of its own built by the migrations before it.
class HelperModelsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261118140000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("helper-models")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Acorn', 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) VALUES (1, 1, 1, 'A', 'Help.', 'm', 'a', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, listed_at, created_at, updated_at) VALUES (1, 1, 1, 'r', '#{now}', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO helpers (conversation_id, call_id, task, created_at, updated_at) VALUES (1, 'toolu_1', 'Look.', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workflows (id, conversation_id, name, kind, created_at, updated_at) VALUES (1, 1, 'Hotels', 'fan_out', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workflow_runs (id, workflow_id, call_id, created_at, updated_at) VALUES (1, 1, 'toolu_w', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workflow_steps (run_id, position, call_id, task, created_at, updated_at) VALUES (1, 1, 'workflow-1-1', 'Look.', '#{now}', '#{now}')")
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing helpers and steps keep everything and name no model of their own; a write from before still saves; it goes back down" do
    before = %w[ helpers workflow_steps ].index_with { @connection.select_all("SELECT * FROM #{it}").to_a }
    run_migrations(:up) { it == VERSION }
    assert_equal [ [ "toolu_1", "running", nil, nil ] ], @connection.select_rows("SELECT call_id, state, model, thinking_level FROM helpers")
    assert_equal [ [ "workflow-1-1", "pending", nil, nil ] ], @connection.select_rows("SELECT call_id, state, model, thinking_level FROM workflow_steps")
    before.each { |table, rows| assert_equal rows, @connection.select_all("SELECT #{rows.first.keys.join(", ")} FROM #{table}").to_a }

    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO helpers (conversation_id, call_id, task, created_at, updated_at) VALUES (1, 'toolu_2', 'More.', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workflow_steps (run_id, position, call_id, task, created_at, updated_at) VALUES (1, 2, 'workflow-1-2', 'More.', '#{now}', '#{now}')")
    assert_equal [ 2, 2 ], %w[ helpers workflow_steps ].map { @connection.select_value("SELECT COUNT(*) FROM #{it}") }

    run_migrations(:down) { it == VERSION }
    %w[ helpers workflow_steps ].each do |table|
      assert_not @connection.column_exists?(table, :model)
      assert_not @connection.column_exists?(table, :thinking_level)
    end
  end

  private
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
