require "test_helper"
require "tmpdir"

# 20261115150000 lets a workspace be shared: every existing membership becomes
# its workspace's owner, and every existing workspace is its person's personal
# one, unnamed (it shows the person's name). A workspace then has exactly one
# owner. Run on a database of its own built by the migrations before it.
class SharedWorkspacesTest < ActiveSupport::TestCase
  VERSION = 20261115150000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("shared-workspaces")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < 20261115070000 }
    [ [ 1, "Maya" ], [ 2, "Robin" ] ].each do |id, name|
      insert "users", id: id, oidc_sub: "sub-#{id}", name: name, email: "#{name.downcase}@example.com"
    end
    run_migrations { it >= 20261115070000 && it < VERSION }
    @maya, @robin = @connection.select_rows("SELECT user_id, workspace_id FROM workspace_memberships ORDER BY user_id").map(&:last)
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "each existing person owns their workspace, which is their personal one and keeps no name" do
    run_migrations { it == VERSION }

    assert_equal [ [ 1, @maya, "owner" ], [ 2, @robin, "owner" ] ],
      @connection.select_rows("SELECT user_id, workspace_id, role FROM workspace_memberships ORDER BY user_id")
    assert_equal [ [ @maya, 1, nil ], [ @robin, 1, nil ] ],
      @connection.select_rows("SELECT id, personal, name FROM workspaces ORDER BY id")
  end

  test "a new workspace is not personal, and a workspace takes members but only one owner" do
    run_migrations { it == VERSION }

    insert "workspaces", id: 9, name: "Household"
    assert_equal 0, @connection.select_value("SELECT personal FROM workspaces WHERE id = 9")
    insert "workspace_memberships", workspace_id: 9, user_id: 1
    insert "workspace_memberships", workspace_id: 9, user_id: 2, role: "member"
    assert_equal [ "owner", "member" ], @connection.select_values("SELECT role FROM workspace_memberships WHERE workspace_id = 9 ORDER BY user_id")

    @connection.execute("DELETE FROM workspace_memberships WHERE workspace_id = 9 AND user_id = 2")
    assert_raises(ActiveRecord::RecordNotUnique) { insert "workspace_memberships", workspace_id: 9, user_id: 2, role: "owner" }
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
