require "test_helper"
require "tmpdir"

# 20261115190000 makes a connector's workspace required, since connectors are
# now reached through it. A connector the release before made without one is
# filled first: a conversation's in its agent's workspace, a person's in their
# personal one. A name is then unique within a workspace, not a person, so the
# install's wiki can be in each of their workspaces. Run on a database of its
# own built by the migrations before it.
class ConnectorWorkspaceRequiredTest < ActiveSupport::TestCase
  VERSION = 20261115190000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("connector-workspace-required")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < 20261115070000 }
    [ [ 1, "Maya" ], [ 2, "Robin" ] ].each do |id, name|
      insert "users", id: id, oidc_sub: "sub-#{id}", name: name, email: "#{name.downcase}@example.com"
    end
    run_migrations { it >= 20261115070000 && it < VERSION }
    @maya, @robin = @connection.select_rows("SELECT user_id, workspace_id FROM workspace_memberships ORDER BY user_id").map(&:last)
    insert "workspaces", id: 9, name: "Household", personal: false
    insert "workspace_memberships", workspace_id: 9, user_id: 1, role: "owner"
    insert "agents", id: 1, user_id: 1, workspace_id: 9, name: "Cook", instructions: "Help.", model: "m", email_name: "cook"
    insert "conversations", id: 1, agent_id: 1, user_id: 1, request_id: "thread", listed_at: Time.current.utc.iso8601
    # Made by the release before during the deploy, without a workspace.
    insert "mcp_servers", id: 1, user_id: 1, name: "mine", url: "https://example.com/mcp"
    insert "mcp_servers", id: 2, user_id: 2, name: "robins", url: "https://example.com/mcp", workspace_id: @robin
    insert "mcp_servers", id: 3, user_id: 1, conversation_id: 1, name: "cooking", url: "https://example.com/mcp"
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a connector without a workspace is filled, and then every connector needs one" do
    run_migrations { it == VERSION }

    assert_equal [ [ 1, @maya ], [ 2, @robin ], [ 3, 9 ] ], @connection.select_rows("SELECT id, workspace_id FROM mcp_servers ORDER BY id")
    assert_not @connection.columns("mcp_servers").find { it.name == "workspace_id" }.null
    assert_raises(ActiveRecord::NotNullViolation) { insert "mcp_servers", id: 4, user_id: 2, name: "late", url: "https://example.com/mcp" }
  end

  test "one person's connector name may be used again in another of their workspaces, never twice in one" do
    run_migrations { it == VERSION }

    insert "mcp_servers", id: 4, user_id: 1, name: "mine", url: "https://example.com/mcp", workspace_id: 9
    assert_raises(ActiveRecord::RecordNotUnique) { insert "mcp_servers", id: 5, user_id: 2, name: "mine", url: "https://example.com/mcp", workspace_id: 9 }
    insert "mcp_servers", id: 6, user_id: 1, conversation_id: 1, name: "mine", url: "https://example.com/mcp", workspace_id: 9
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
