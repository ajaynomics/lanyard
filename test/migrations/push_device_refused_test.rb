require "test_helper"
require "tmpdir"

# 20261125040000 adds whether iOS last refused an iPhone's notifications.
# Every existing device keeps its row and token, not refused, so its iPhone
# still says On until the app's next report.
# Run on a database of its own built by the migrations before it.
class PushDeviceRefusedMigrationTest < ActiveSupport::TestCase
  VERSION = 20261125040000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("push-device-refused")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an existing device keeps its row and token, not refused" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO push_devices (id, user_id, token, environment, session_digest, created_at, updated_at) VALUES (1, 1, '#{"ab" * 32}', 'sandbox', 'd1', '#{now}', '#{now}')")
    run_migrations { it == VERSION }
    assert_equal [ [ 1, 1, "ab" * 32, "sandbox", "d1", 0 ] ],
      @connection.select_rows("SELECT id, user_id, token, environment, session_digest, refused FROM push_devices")
    assert_not_includes @connection.columns(:push_devices).map(&:name), "reported_at", "Rails orders reports as they arrive, not by the phone's clock"
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
