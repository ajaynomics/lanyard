require "test_helper"
require "tmpdir"

# 20261112040000 adds a connector's "Ask before every write": every connector
# already there is off, as it was, and the column goes again on the way down.
# Run on a database of its own built by the migrations before it.
class AsksEveryWriteTest < ActiveSupport::TestCase
  VERSION = 20261112040000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("asks_every_write")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "connectors already there don't ask before every write, and the column goes on the way down" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO mcp_servers (id, user_id, name, url, created_at, updated_at) VALUES (1, 1, 'chat', 'https://chat.example.com/mcp', '#{now}', '#{now}')")
    run_migrations(:up) { it == VERSION }

    assert_equal [ [ 1, "chat", 0 ] ], @connection.select_rows("SELECT id, name, asks_every_write FROM mcp_servers")
    @connection.execute("INSERT INTO mcp_servers (id, user_id, name, url, created_at, updated_at) VALUES (2, 1, 'chat_2', 'https://chat.example.com/mcp', '#{now}', '#{now}')")
    assert_equal 0, @connection.select_value("SELECT asks_every_write FROM mcp_servers WHERE id = 2")

    run_migrations(:down) { it == VERSION }
    assert_not_includes @connection.columns(:mcp_servers).map(&:name), "asks_every_write"
    assert_equal [ [ 1, "chat" ], [ 2, "chat_2" ] ], @connection.select_rows("SELECT id, name FROM mcp_servers ORDER BY id")
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
