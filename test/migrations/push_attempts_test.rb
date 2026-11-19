require "test_helper"
require "tmpdir"

# 20261115060000 adds what became of each Turn on in the phone app. Nothing
# already there changes: everyone keeps their devices, and nobody has an
# attempt until the next one. Run on a database of its own built by the
# migrations before it.
class PushAttemptsTest < ActiveSupport::TestCase
  VERSION = 20261115060000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("push-attempts")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a person and their phone's device stay as they were, with no attempt yet; an attempt goes with its person" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO push_devices (id, user_id, token, created_at, updated_at) VALUES (1, 1, '#{"ab" * 32}', '#{now}', '#{now}')")
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "maya@example.com" ] ], @connection.select_rows("SELECT id, email FROM users")
    assert_equal [ [ 1, 1 ] ], @connection.select_rows("SELECT id, user_id FROM push_devices")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM push_attempts")
    @connection.execute("INSERT INTO push_attempts (user_id, outcome, created_at) VALUES (1, 'no_answer', '#{now}')")
    assert_equal [ [ "no_answer", nil, "" ] ], @connection.select_rows("SELECT outcome, code, user_agent FROM push_attempts")
    @connection.execute("PRAGMA foreign_keys = ON")
    @connection.execute("DELETE FROM users WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM push_attempts")
  end

  private
    def run_migrations
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, :up) }
      end
    end
end
