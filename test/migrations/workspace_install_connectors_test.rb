require "test_helper"
require "tmpdir"

# 20261117010100 adds a workspace's own address and key for an install
# connector (Workspace::InstallConnector): a new, empty table, so every
# workspace keeps the install's, as before. One per connector name in a
# workspace; deleting a workspace, as code from before does without knowing
# it, takes its rows with it; it goes back down cleanly. Run on a database of
# its own built by the migrations before it, then it alone.
class WorkspaceInstallConnectorsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261117010100
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-install-connectors")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    @now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Acorn', 0, '#{@now}', '#{@now}')")
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing workspaces have none of their own; one per name; it goes with its workspace; it goes back down" do
    before = @connection.select_all("SELECT * FROM workspaces").to_a
    run_migrations(:up) { it == VERSION }
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_install_connectors")
    assert_equal before, @connection.select_all("SELECT * FROM workspaces").to_a

    insert = "INSERT INTO workspace_install_connectors (workspace_id, name, api_key, created_at, updated_at) VALUES (1, 'wiki', 'k', '#{@now}', '#{@now}')"
    @connection.execute(insert)
    assert_raises(ActiveRecord::RecordNotUnique) { @connection.execute(insert) }
    @connection.execute("DELETE FROM workspaces WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_install_connectors")

    run_migrations(:down) { it == VERSION }
    assert_not @connection.table_exists?(:workspace_install_connectors)
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
