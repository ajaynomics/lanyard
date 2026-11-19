require "test_helper"
require "tmpdir"

# 20261113000000 adds the table of a person's Watches. It only adds a table:
# existing people are untouched, a person's Watches go with them, one token's
# digest names one Watch, and the step can be undone. Run on a database of its
# own built by the migrations before it.
class WatchesMigrationTest < ActiveSupport::TestCase
  VERSION = 20261113000000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("watches")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a person's Watches go with them, a digest names one Watch, and it undoes" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    tables = @connection.tables
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "Maya" ] ], @connection.select_rows("SELECT id, name FROM users")
    insert = -> { @connection.execute("INSERT INTO watches (user_id, name, token_digest, created_at, updated_at) VALUES (1, 'Watch', 'd1', '#{now}', '#{now}')") }
    insert.()
    assert_equal [ [ "Watch", nil, nil ] ], @connection.select_rows("SELECT name, last_used_at, revoked_at FROM watches")
    assert_raises(ActiveRecord::RecordNotUnique) { insert.() }
    @connection.execute("PRAGMA foreign_keys = ON")
    @connection.execute("DELETE FROM users WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM watches")

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
