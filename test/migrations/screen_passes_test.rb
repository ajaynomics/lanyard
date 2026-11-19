require "test_helper"
require "tmpdir"

# 20261116170000 adds one-time screen links (ScreenPass): a new, empty table.
# Code from before deletes conversations and people without knowing it, so
# its keys cascade; it goes back down cleanly. Run on a database of its own
# built by the migrations before it, then it alone.
class ScreenPassesMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116170000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("screen-passes")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Rob', 'rob@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, listed_at, created_at, updated_at) VALUES (1, 1, 1, 'r1', '#{now}', '#{now}', '#{now}')")
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "the table starts empty, its links go with their conversation as code from before deletes it, and it goes back down" do
    run_migrations(:up) { it == VERSION }
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM screen_passes")

    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO screen_passes (conversation_id, created_by_id, token_digest, expires_at, created_at, updated_at) " \
      "VALUES (1, 1, 'd', '#{now}', '#{now}', '#{now}')")
    @connection.execute("DELETE FROM conversations WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM screen_passes")

    run_migrations(:down) { it == VERSION }
    assert_not @connection.table_exists?(:screen_passes)
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
