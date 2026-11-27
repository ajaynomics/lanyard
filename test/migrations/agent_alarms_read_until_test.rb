require "test_helper"
require "tmpdir"

# 20261126090000 keeps how far each agent's alarms were mailed
# (AlarmMailerJob). Additive: every existing agent has read none, so its first
# read starts then rather than mailing what came due before. Run on a database
# of its own built by the migrations before it.
class AgentAlarmsReadUntilTest < ActiveSupport::TestCase
  VERSION = 20261126090000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("alarms-read-until")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an existing agent has read no alarms yet" do
    insert_agent
    run_migrations { it == VERSION }

    assert_equal [ [ 1, nil ] ], @connection.select_rows("SELECT id, alarms_read_until FROM agents")
  end

  private
    def insert_agent
      now = Time.current.utc.iso8601
      @connection.execute("INSERT INTO workspaces (id, name, created_at, updated_at) VALUES (1, 'Home', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
      @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
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
