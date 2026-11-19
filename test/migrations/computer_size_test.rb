require "test_helper"
require "tmpdir"

# 20261117060000 lets a workspace and an agent's computer each set the size
# of the Sprites made for it. Additive: every existing workspace and computer,
# and one made by code from before during a rolling deploy, sets none, so its
# Sprites are made at today's size. Run on a database of its own built by the
# migrations before it, then its own alone.
class ComputerSizeMigrationTest < ActiveSupport::TestCase
  VERSION = 20261117060000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("computer-size")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing workspaces and computers, and ones made by code from before, set no size" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO computers (id, agent_id, name, provider, created_at, updated_at) VALUES (1, 1, 'ss-b1', 'sprites', '#{now}', '#{now}')")

    run_migrations { it == VERSION }

    assert_equal [ [ 1, nil, nil, nil ] ], @connection.select_rows("SELECT id, computer_cpus, computer_memory_mib, computer_disk_mib FROM workspaces")
    assert_equal [ [ 1, nil, nil, nil ] ], @connection.select_rows("SELECT id, cpus, memory_mib, disk_mib FROM computers")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (2, 'Team', 0, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (2, 1, 2, 'Juno', 'Help.', 'm', 'juno', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO computers (id, agent_id, name, created_at, updated_at) VALUES (2, 2, 'ss-b2', '#{now}', '#{now}')")
    assert_equal [ nil, nil, nil ], @connection.select_rows("SELECT computer_cpus, computer_memory_mib, computer_disk_mib FROM workspaces WHERE id = 2").sole
    assert_equal [ nil, nil, nil ], @connection.select_rows("SELECT cpus, memory_mib, disk_mib FROM computers WHERE id = 2").sole
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
