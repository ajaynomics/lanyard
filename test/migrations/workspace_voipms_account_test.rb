require "test_helper"
require "tmpdir"

# 20261118200000 lets a workspace name its own voip.ms account, by vault entry
# (docs/phone.md). Every existing workspace has none, so every agent's texts
# go on through the install's account. Run on a database of its own built by
# the migrations before it.
class WorkspaceVoipmsAccountMigrationTest < ActiveSupport::TestCase
  VERSION = 20261118200000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-voipms")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
    insert "workspaces", id: 1, personal: true
    insert "workspaces", id: 3, personal: false, name: "Team", campfire_vault_entry: "Team Campfire"
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "no workspace has a voip.ms account of its own, so every agent texts through the install's; nothing else changes" do
    run_migrations { it == VERSION }

    assert_equal [ [ 1, nil, nil ], [ 3, "Team", nil ] ], @connection.select_rows("SELECT id, name, voipms_vault_entry FROM workspaces ORDER BY id")
    assert_equal "Team Campfire", @connection.select_value("SELECT campfire_vault_entry FROM workspaces WHERE id = 3")
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

    def insert(table, **values)
      now = Time.current.utc.iso8601
      columns = @connection.columns(table).map(&:name)
      values = { created_at: now, updated_at: now }.select { |column, _| columns.include?(column.to_s) }.merge(values)
      @connection.execute("INSERT INTO #{table} (#{values.keys.join(', ')}) VALUES (#{values.values.map { @connection.quote(it) }.join(', ')})")
    end
end
