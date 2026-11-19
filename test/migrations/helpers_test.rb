require "test_helper"
require "tmpdir"

# 20261112030000 adds the table of helpers an agent started in the background.
# It only adds a table: existing conversations are untouched, a conversation's
# helpers go with it, a call starts one helper, and the step can be undone.
# Run on a database of its own built by the migrations before it.
class HelpersMigrationTest < ActiveSupport::TestCase
  VERSION = 20261112030000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("helpers")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a conversation's helpers go with it, a call starts one, and it undoes" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) VALUES (1, 1, 'A', 'Help.', 'm', 'a', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, listed_at, created_at, updated_at) VALUES (1, 1, 1, 'r', '#{now}', '#{now}', '#{now}')")
    tables = @connection.tables
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "r" ] ], @connection.select_rows("SELECT id, request_id FROM conversations")
    insert = ->(call) { @connection.execute("INSERT INTO helpers (conversation_id, call_id, task, created_at, updated_at) VALUES (1, '#{call}', 'Look.', '#{now}', '#{now}')") }
    insert.("toolu_1")
    assert_equal [ [ "toolu_1", "running", "[]", 0 ] ], @connection.select_rows("SELECT call_id, state, calls, call_count FROM helpers")
    assert_raises(ActiveRecord::RecordNotUnique) { insert.("toolu_1") }
    @connection.execute("PRAGMA foreign_keys = ON")
    @connection.execute("DELETE FROM conversations WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM helpers")

    run_migrations(:down) { it == VERSION }
    assert_equal tables.sort, @connection.tables.sort
  end

  private
    def run_migrations(direction = :up)
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
