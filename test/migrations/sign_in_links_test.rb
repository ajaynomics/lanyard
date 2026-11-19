require "test_helper"
require "tmpdir"

# 20261116220000 adds one-time links for someone outside to fill a saved
# sign-in (SignInLink): a new, empty table. Code from before deletes
# conversations, calls and people without knowing it, so its keys cascade, and
# forget who revoked a link when that person goes; it goes back down cleanly.
# Run on a database of its own built by the migrations before it, then it alone.
class SignInLinksMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116220000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("sign-in-links")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Rob', 'rob@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (2, 't', 'Sam', 'sam@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, listed_at, created_at, updated_at) VALUES (1, 1, 1, 'r1', '#{now}', '#{now}', '#{now}')")
    insert_invocation(1)
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "the table starts empty, its links go with their call and conversation as code from before deletes them, and it goes back down" do
    run_migrations(:up) { it == VERSION }
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM sign_in_links")

    insert_link(1, invocation: 1, revoked_by: 2)
    @connection.execute("DELETE FROM users WHERE id = 2")
    assert_equal [ nil ], @connection.select_rows("SELECT revoked_by_id FROM sign_in_links").sole, "who revoked it is forgotten, the link kept"
    @connection.execute("DELETE FROM invocations WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM sign_in_links")

    # Conversation#destroy from before: its calls first, then itself.
    insert_invocation(2)
    insert_link(2, invocation: 2)
    @connection.execute("DELETE FROM invocations WHERE conversation_id = 1")
    @connection.execute("DELETE FROM conversations WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM sign_in_links")

    assert_raises(ActiveRecord::RecordNotUnique) do
      insert_invocation(3)
      insert_link(3, invocation: 3, digest: "same")
      insert_link(4, invocation: 3, digest: "same")
    end

    run_migrations(:down) { it == VERSION }
    assert_not @connection.table_exists?(:sign_in_links)
  end

  private
    def now = Time.current.utc.iso8601

    def insert_invocation(id)
      @connection.execute("INSERT OR IGNORE INTO conversations (id, user_id, agent_id, request_id, listed_at, created_at, updated_at) VALUES (1, 1, 1, 'r1', '#{now}', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO invocations (id, conversation_id, task_id, call_id, tool_name, arguments, digest, state, created_at, updated_at) " \
        "VALUES (#{id}, 1, '7', 'toolu_#{id}', 'ask_outside_for_sign_in', '{}', 'd', 'succeeded', '#{now}', '#{now}')")
    end

    def insert_link(id, invocation:, revoked_by: nil, digest: "d#{id}")
      @connection.execute("INSERT INTO sign_in_links (id, conversation_id, invocation_id, revoked_by_id, entry_id, name, token_digest, expires_at, created_at, updated_at) " \
        "VALUES (#{id}, 1, #{invocation}, #{revoked_by || "NULL"}, 'e', 'Bank', '#{digest}', '#{now}', '#{now}', '#{now}')")
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
