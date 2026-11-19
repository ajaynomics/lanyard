require "test_helper"
require "tmpdir"

# 20261118170000 adds the table of sends recorded before their provider is
# asked (Dispatch). It changes no existing row; code from before it (a
# rollback image, or the old half of a rolling deploy) deletes calls and
# conversations without knowing the table is there, so a dispatch must go
# with its call in the database itself. Run on a database of its own built
# by the migrations before it, then it alone, and then back down.
class CreateDispatchesMigrationTest < ActiveSupport::TestCase
  VERSION = 20261118170000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("create-dispatches")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    seed
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "the calls made before it are unchanged, a dispatch goes with its call as code from before deletes it, and outlives who closed it" do
    before = @connection.select_rows("SELECT * FROM invocations")
    run_migrations(:up) { it == VERSION }
    assert_equal before, @connection.select_rows("SELECT * FROM invocations")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM dispatches")

    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO dispatches (invocation_id, key, tool_name, state, sender, fingerprint, created_at, updated_at) " \
      "VALUES (1, 'k1', 'send_text', 'checking', '6475550123', 'f', '#{now}', '#{now}')")
    assert_raises(ActiveRecord::RecordNotUnique, "one a call") do
      @connection.execute("INSERT INTO dispatches (invocation_id, key, tool_name, state, sender, fingerprint, created_at, updated_at) " \
        "VALUES (1, 'k2', 'send_text', 'pending', '6475550123', 'f', '#{now}', '#{now}')")
    end

    # The person who said whether it went is only recorded.
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (2, 's2', 'Robin', 'robin@example.com', '#{now}', '#{now}')")
    @connection.execute("UPDATE dispatches SET closed_by_id = 2")
    @connection.execute("DELETE FROM users WHERE id = 2")
    assert_equal [ [ 1, nil ] ], @connection.select_rows("SELECT invocation_id, closed_by_id FROM dispatches")

    # Conversation#destroy from before: its calls first, then itself.
    @connection.execute("DELETE FROM invocations WHERE conversation_id = 1")
    @connection.execute("DELETE FROM conversations WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM dispatches")
  end

  test "it goes back down, keeping the calls" do
    run_migrations(:up) { it == VERSION }
    run_migrations(:down) { it == VERSION }
    assert_not @connection.table_exists?(:dispatches)
    assert_equal 1, @connection.select_value("SELECT COUNT(*) FROM invocations")
  end

  private
    def seed
      now = Time.current.utc.iso8601
      @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
      @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, listed_at, created_at, updated_at) " \
        "VALUES (1, 1, 1, 'r1', '#{now}', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO invocations (id, conversation_id, task_id, call_id, tool_name, arguments, digest, state, created_at, updated_at) " \
        "VALUES (1, 1, '1', 'c1', 'send_text', '{}', 'd', 'failed', '#{now}', '#{now}')")
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
