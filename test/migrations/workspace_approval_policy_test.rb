require "test_helper"
require "tmpdir"

# 20261118191500 gives a workspace its own approval policy (#226), none at
# first, so every workspace keeps the install's and nothing asks more or less
# on deploy. The release before still saves a workspace during the deploy.
# Run on a database of its own built by the migrations before it.
class WorkspaceApprovalPolicyMigrationTest < ActiveSupport::TestCase
  VERSION = 20261118191500
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-approval-policy")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
    insert "workspaces", id: 1, personal: true
    insert "workspaces", id: 2, personal: false, name: "Household"
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "every workspace is left on the install's policy, and one the release before saves during the deploy is too" do
    run_migrations { it == VERSION }

    assert_equal [ [ 1, nil ], [ 2, nil ] ], @connection.select_rows("SELECT id, approval_policy FROM workspaces ORDER BY id")
    @connection.execute("INSERT INTO workspaces (id, personal, name, created_at, updated_at) VALUES (3, 0, 'Late', '2026-11-18', '2026-11-18')")
    assert_nil @connection.select_value("SELECT approval_policy FROM workspaces WHERE id = 3")
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
