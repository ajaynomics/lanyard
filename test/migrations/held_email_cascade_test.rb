require "test_helper"
require "tmpdir"

# 20261116160000 lets the database remove a held email with its conversation
# or call, and forget who cancelled one when that person goes. Code from
# before held emails existed (a rollback image) deletes conversations, agents
# and people without knowing the table is there; without this, any held email
# made that delete fail on its foreign key. Run on a database of its own built
# by the migrations before it, then it alone, and then back down.
class HeldEmailCascadeMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116160000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("held-email-cascade")
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

  test "a held email made before it is kept, and goes with its conversation and call, as code from before deletes them" do
    run_migrations(:up) { it == VERSION }

    assert_equal [ [ 1, 1, 1, "held", 2 ] ], @connection.select_rows("SELECT id, conversation_id, invocation_id, state, cancelled_by_id FROM held_emails")
    @connection.execute("DELETE FROM users WHERE id = 2")
    assert_equal [ nil ], @connection.select_rows("SELECT cancelled_by_id FROM held_emails").sole
    @connection.execute("DELETE FROM invocations WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM held_emails")

    # Conversation#destroy from before: its calls first, then itself.
    insert_invocation_and_held(2)
    @connection.execute("DELETE FROM invocations WHERE conversation_id = 1")
    @connection.execute("DELETE FROM conversations WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM held_emails")
  end

  test "before it, the same delete fails: the case it fixes" do
    assert_raises(ActiveRecord::InvalidForeignKey) { @connection.execute("DELETE FROM invocations WHERE id = 1") }
  end

  test "it goes back down to plain foreign keys, keeping the rows" do
    run_migrations(:up) { it == VERSION }
    run_migrations(:down) { it == VERSION }

    assert_equal 1, @connection.select_value("SELECT COUNT(*) FROM held_emails")
    assert_raises(ActiveRecord::InvalidForeignKey) { @connection.execute("DELETE FROM invocations WHERE id = 1") }
  end

  private
    def seed
      now = Time.current.utc.iso8601
      @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (2, 't', 'Rob', 'rob@example.com', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
      @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, listed_at, created_at, updated_at) " \
        "VALUES (1, 1, 1, 'r1', '#{now}', '#{now}', '#{now}')")
      insert_invocation_and_held(1, cancelled_by: 2)
    end

    def insert_invocation_and_held(id, cancelled_by: "NULL")
      now = Time.current.utc.iso8601
      @connection.execute("INSERT INTO invocations (id, conversation_id, task_id, call_id, tool_name, arguments, digest, created_at, updated_at) " \
        "VALUES (#{id}, 1, '1', 'c#{id}', 'send_email', '{}', 'd', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO held_emails (id, conversation_id, invocation_id, send_at, state, cancelled_by_id, created_at, updated_at) " \
        "VALUES (#{id}, 1, #{id}, '#{now}', 'held', #{cancelled_by}, '#{now}', '#{now}')")
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
