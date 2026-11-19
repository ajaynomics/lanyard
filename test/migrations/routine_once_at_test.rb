require "test_helper"
require "tmpdir"

# 20261116110000 lets a routine run once at a time (#81). Additive: every
# existing routine, and one code from before writes during a rolling deploy,
# repeats as before. A one-off keeps a schedule too, its minute, hour, day and
# month as cron, so code from before reads it as a routine it can run.
class RoutineOnceAtTest < ActiveSupport::TestCase
  VERSION = 20261116110000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("once-at")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing routines, and one written by code from before, repeat; a one-off still has a schedule" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Home', 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO routines (id, agent_id, schedule, prompt, created_at, updated_at) VALUES (1, 1, 'every day at 8am', 'Brief me.', '#{now}', '#{now}')")

    run_migrations { it == VERSION }

    assert_nil @connection.select_value("SELECT once_at FROM routines WHERE id = 1")
    @connection.execute("INSERT INTO routines (id, agent_id, schedule, prompt, created_at, updated_at) VALUES (2, 1, 'every day at 9am', 'Plan.', '#{now}', '#{now}')")
    assert_nil @connection.select_value("SELECT once_at FROM routines WHERE id = 2")
    assert_raises(ActiveRecord::NotNullViolation) do
      @connection.execute("INSERT INTO routines (id, agent_id, once_at, prompt, created_at, updated_at) VALUES (3, 1, '#{now}', 'x', '#{now}', '#{now}')")
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
