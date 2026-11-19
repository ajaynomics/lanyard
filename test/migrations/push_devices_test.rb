require "test_helper"
require "tmpdir"

# 20261113020000 adds the phone app's devices for Apple's push service. Nothing
# already there changes: everyone's browsers keep their Web Push, and nobody
# has a device until the app registers one. Run on a database of its own built
# by the migrations before it.
class PushDevicesTest < ActiveSupport::TestCase
  VERSION = 20261113020000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("push-devices")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a person and their browser's notifications stay as they were, with no device yet; a token is one phone's" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO push_subscriptions (id, user_id, endpoint, p256dh_key, auth_key, created_at, updated_at) VALUES (1, 1, 'https://web.push.apple.com/x', 'k', 'a', '#{now}', '#{now}')")
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "maya@example.com" ] ], @connection.select_rows("SELECT id, email FROM users")
    assert_equal [ [ 1, 1 ] ], @connection.select_rows("SELECT id, user_id FROM push_subscriptions")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM push_devices")
    @connection.execute("INSERT INTO push_devices (user_id, token, created_at, updated_at) VALUES (1, 'ab', '#{now}', '#{now}')")
    assert_equal "production", @connection.select_value("SELECT environment FROM push_devices")
    assert_raises(ActiveRecord::RecordNotUnique) do
      @connection.execute("INSERT INTO push_devices (user_id, token, created_at, updated_at) VALUES (1, 'ab', '#{now}', '#{now}')")
    end
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
