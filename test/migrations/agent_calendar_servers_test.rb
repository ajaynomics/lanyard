require "test_helper"
require "tmpdir"

# 20261116130000 adds where an agent's own calendar lives (#77), a table of
# its own. Additive: every existing agent, and one made by code from before
# during a rolling deploy, has none and so keeps the install's account.
class AgentCalendarServersMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116130000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("calendar-servers")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing agents, and one made by code from before, have none; one is one per agent" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    insert_agent(1, now)

    run_migrations { it == VERSION }

    insert_agent(2, now)
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM agent_calendar_servers")
    assert_equal [ [ "iris", "secret" ] ], @connection.select_rows("SELECT caldav_username, caldav_password FROM agents WHERE id = 1")
    insert = "INSERT INTO agent_calendar_servers (agent_id, url, vault_entry, created_at, updated_at) " \
      "VALUES (1, 'https://dav.example.com/desk/', 'Desk', '#{now}', '#{now}')"
    @connection.execute(insert)
    assert_raises(ActiveRecord::RecordNotUnique) { @connection.execute(insert) }
  end

  private
    def insert_agent(id, now)
      @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, caldav_username, caldav_password, created_at, updated_at) " \
        "VALUES (#{id}, 1, 1, 'Agent #{id}', 'Help.', 'm', 'agent#{id}', 'iris', 'secret', '#{now}', '#{now}')")
    end

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
