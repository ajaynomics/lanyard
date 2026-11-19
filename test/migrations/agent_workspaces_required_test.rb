require "test_helper"
require "tmpdir"

# 20261115120000 puts each agent still without a workspace into its person's
# own, making one for a person who has none, and then requires it. Agents
# already in one stay there. Run on a database of its own built by the
# migrations before it.
class AgentWorkspacesRequiredTest < ActiveSupport::TestCase
  VERSION = 20261115120000
  WORKSPACES = 20261115070000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("agent-workspaces")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    # Maya (1) and Robin (2) had workspaces made for them; Sam (3) signed in
    # on the old release during the deploy, and has none.
    run_migrations { it < WORKSPACES }
    [ [ 1, "Maya" ], [ 2, "Robin" ] ].each do |id, name|
      insert "users", id: id, oidc_sub: "sub-#{id}", name: name, email: "#{name.downcase}@example.com"
    end
    run_migrations { it >= WORKSPACES && it < VERSION }
    insert "users", id: 3, oidc_sub: "sub-3", name: "Sam", email: "sam@example.com"
    @maya, @robin = @connection.select_rows("SELECT user_id, workspace_id FROM workspace_memberships ORDER BY user_id").map(&:last)
    insert "agents", id: 1, user_id: 1, workspace_id: @maya, name: "Placed", instructions: "Help.", model: "m", email_name: "placed"
    insert "agents", id: 2, user_id: 1, name: "Late", instructions: "Help.", model: "m", email_name: "late"
    insert "agents", id: 3, user_id: 2, name: "Robin's", instructions: "Help.", model: "m", email_name: "robins"
    insert "agents", id: 4, user_id: 3, name: "Sam's", instructions: "Help.", model: "m", email_name: "sams"
    insert "agents", id: 5, user_id: 3, name: "Sam's other", instructions: "Help.", model: "m", email_name: "sams-other"
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an agent without a workspace goes into its person's own, and one in a workspace stays" do
    run_migrations { it == VERSION }

    sam = @connection.select_value("SELECT workspace_id FROM workspace_memberships WHERE user_id = 3")
    assert sam, "Sam gets a workspace of his own, with him its member"
    assert_equal [ @maya, @robin, sam ].uniq.size, 3
    assert_equal [ [ 1, 1, @maya ], [ 2, 1, @maya ], [ 3, 2, @robin ], [ 4, 3, sam ], [ 5, 3, sam ] ],
      @connection.select_rows("SELECT id, user_id, workspace_id FROM agents ORDER BY id")
    assert_equal 3, @connection.select_value("SELECT COUNT(*) FROM workspaces")
  end

  test "an agent can no longer be saved without a workspace" do
    run_migrations { it == VERSION }

    assert_not @connection.columns("agents").find { it.name == "workspace_id" }.null
    assert_raises(ActiveRecord::NotNullViolation) do
      insert "agents", id: 6, user_id: 1, name: "Later", instructions: "Help.", model: "m", email_name: "later"
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

    def insert(table, **values)
      now = Time.current.utc.iso8601
      columns = @connection.columns(table).map(&:name)
      values = { created_at: now, updated_at: now }.select { |column, _| columns.include?(column.to_s) }.merge(values)
      @connection.execute("INSERT INTO #{table} (#{values.keys.join(', ')}) VALUES (#{values.values.map { @connection.quote(it) }.join(', ')})")
    end
end
