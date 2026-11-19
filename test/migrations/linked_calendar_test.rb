require "test_helper"
require "tmpdir"

# 20261115040000 adds an agent's linked calendar: a server, a calendar and a
# vault entry's name. Every existing agent keeps its row, its own calendar
# account included, and links none. Run on a database of its own built by the
# migrations before it.
class LinkedCalendarMigrationTest < ActiveSupport::TestCase
  VERSION = 20261115040000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("linked-calendar")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an existing agent keeps its row and its own account, and links no calendar" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, caldav_username, created_at, updated_at) " \
      "VALUES (1, 1, 'Maya', 'Help.', 'm', 'maya', 'agent-1', '#{now}', '#{now}')")
    run_migrations { it == VERSION }
    assert_equal [ [ 1, "Maya", "agent-1", nil, nil, nil ] ],
      @connection.select_rows("SELECT id, name, caldav_username, linked_calendar_server, linked_calendar, linked_calendar_entry FROM agents")
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
