require "test_helper"
require "tmpdir"

# 20261115070000 gives each existing person a workspace of their own, with
# them its one member, and puts their agents in it. Nothing else changes:
# agents keep their person, and a person with no agents still gets one. Run on
# a database of its own built by the migrations before it.
class WorkspacesTest < ActiveSupport::TestCase
  VERSION = 20261115070000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspaces")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
    [ [ 1, "Maya" ], [ 2, "Robin" ], [ 3, "Sam" ] ].each do |id, name|
      insert "users", id: id, oidc_sub: "sub-#{id}", name: name, email: "#{name.downcase}@example.com"
    end
    [ [ 1, 1 ], [ 2, 1 ], [ 3, 2 ] ].each do |id, user_id|
      insert "agents", id: id, user_id: user_id, name: "Agent #{id}", instructions: "Help.", model: "m", email_name: "agent-#{id}"
    end
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "each person gets their own workspace, with them its one member and their agents in it" do
    run_migrations { it == VERSION }

    memberships = @connection.select_rows("SELECT user_id, workspace_id FROM workspace_memberships ORDER BY user_id").to_h
    assert_equal [ 1, 2, 3 ], memberships.keys
    assert_equal 3, memberships.values.uniq.size, "one workspace each"
    assert_equal 3, @connection.select_value("SELECT COUNT(*) FROM workspaces")
    assert_equal [ [ 1, 1, memberships[1] ], [ 2, 1, memberships[1] ], [ 3, 2, memberships[2] ] ],
      @connection.select_rows("SELECT id, user_id, workspace_id FROM agents ORDER BY id")
  end

  test "an agent the old release makes during the deploy is still saved, without a workspace" do
    run_migrations { it == VERSION }

    insert "agents", id: 4, user_id: 3, name: "Late", instructions: "Help.", model: "m", email_name: "late"
    assert_nil @connection.select_value("SELECT workspace_id FROM agents WHERE id = 4")
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
