require "test_helper"
require "tmpdir"

# 20261117010000 lets a workspace hold its own Passbolt user: two empty
# columns, so every existing workspace is as it was and its agents stay on the
# install's user (DurableAssistants::Passbolt.key_for). Code from before writes
# a workspace without knowing them; it goes back down cleanly. Run on a
# database of its own built by the migrations before it, then it alone.
class WorkspaceVaultUserMigrationTest < ActiveSupport::TestCase
  VERSION = 20261117010000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-vault-user")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Acorn', 0, '#{now}', '#{now}')")
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing workspaces keep everything and hold no user of their own; a write from before still saves; it goes back down" do
    before = @connection.select_all("SELECT * FROM workspaces").to_a
    run_migrations(:up) { it == VERSION }
    assert_equal [ [ nil, nil ] ], @connection.select_rows("SELECT passbolt_private_key, passbolt_passphrase FROM workspaces")
    assert_equal before, @connection.select_all("SELECT id, created_at, updated_at, name, personal FROM workspaces").to_a

    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (2, 'Birch', 0, '#{now}', '#{now}')")
    assert_equal 2, @connection.select_value("SELECT COUNT(*) FROM workspaces")

    run_migrations(:down) { it == VERSION }
    assert_not @connection.column_exists?(:workspaces, :passbolt_private_key)
    assert_not @connection.column_exists?(:workspaces, :passbolt_passphrase)
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
