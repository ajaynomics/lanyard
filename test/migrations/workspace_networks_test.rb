require "test_helper"
require "tmpdir"

# 20261117020000 gives a workspace its own Concourse home network and Campfire
# (docs/design/workspaces.md, 2.1 and 2.3), none at first, so every workspace
# goes on as before. Every Concourse identity already joined is marked an
# approved bridge, approved by its workspace's owner, so whichever home network
# an owner names later, nothing live stops. A Campfire room's loop hold is
# copied from a person to a workspace, their personal one, into a table of its
# own; the release before keeps its own table. Run on a database of its own
# built by the migrations before it.
class WorkspaceNetworksMigrationTest < ActiveSupport::TestCase
  VERSION = 20261117020000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-networks")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
    insert "users", id: 1, oidc_sub: "s-1", name: "Maya", email: "maya@example.com"
    insert "users", id: 2, oidc_sub: "s-2", name: "Robin", email: "robin@example.com"
    insert "workspaces", id: 1, personal: true
    insert "workspaces", id: 2, personal: true
    insert "workspaces", id: 3, personal: false, name: "Team"
    insert "workspace_memberships", workspace_id: 1, user_id: 1, role: "owner"
    insert "workspace_memberships", workspace_id: 2, user_id: 2, role: "owner"
    insert "workspace_memberships", workspace_id: 3, user_id: 2, role: "owner"
    insert "workspace_memberships", workspace_id: 3, user_id: 1, role: "member"
    insert "agents", id: 1, user_id: 1, workspace_id: 1, name: "Ada", instructions: "Help.", model: "m", email_name: "ada"
    insert "agents", id: 2, user_id: 1, workspace_id: 3, name: "Bea", instructions: "Help.", model: "m", email_name: "bea"
    insert "concourse_agents", id: 1, agent_id: 1, organization: "acme", handle: "acme/ada", client_id: "c", client_secret: "s"
    insert "concourse_agents", id: 2, agent_id: 2, organization: "acme", handle: "acme/bea", client_id: "c", client_secret: "s"
    insert "concourse_agents", id: 3, agent_id: 2, organization: "pilot", handle: "pilot/bea", client_id: "c", client_secret: "s"
    insert "campfire_rooms", id: 1, user_id: 1, room_id: 1, held_at: Time.current.utc.iso8601
    insert "campfire_rooms", id: 2, user_id: 2, room_id: 1
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "no workspace has a home network or a Campfire of its own; every identity is a bridge its workspace's owner approved; a hold is its person's own workspace's" do
    run_migrations { it == VERSION }

    assert_equal [ [ nil, nil, nil ] ], @connection.select_rows("SELECT DISTINCT concourse_home, campfire_url, campfire_vault_entry FROM workspaces")
    assert_equal [ [ 1, 1 ], [ 2, 2 ], [ 3, 2 ] ], @connection.select_rows("SELECT id, bridge_approved_by_id FROM concourse_agents ORDER BY id"),
      "Maya owns Ada's workspace; Robin owns Team, where Bea is"
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM concourse_agents WHERE bridge_approved_at IS NULL")
    assert_equal [ [ 1, 1, true ], [ 2, 1, false ] ],
      @connection.select_rows("SELECT workspace_id, room_id, held_at IS NOT NULL FROM workspace_campfire_rooms ORDER BY workspace_id").map { [ it[0], it[1], it[2] == 1 ] },
      "Maya's hold, still held, is her own workspace's; Robin's his"
    assert_equal 2, @connection.select_value("SELECT COUNT(*) FROM campfire_rooms"), "the release before keeps its own"
  end

  test "the release before still saves its identities and rooms during the deploy; a workspace's holds go with it, and a person's old ones with them" do
    run_migrations { it == VERSION }

    insert "concourse_agents", id: 4, agent_id: 1, organization: "late", handle: "late/ada", client_id: "c", client_secret: "s"
    assert_nil @connection.select_value("SELECT bridge_approved_by_id FROM concourse_agents WHERE id = 4")
    insert "campfire_rooms", id: 3, user_id: 1, room_id: 5
    insert "workspace_campfire_rooms", workspace_id: 3, room_id: 1

    @connection.execute("PRAGMA foreign_keys = ON")
    @connection.execute("DELETE FROM concourse_agents")
    @connection.execute("DELETE FROM agents")
    @connection.execute("DELETE FROM workspace_memberships WHERE workspace_id = 3")
    @connection.execute("DELETE FROM workspaces WHERE id = 3")
    assert_equal [ 1, 2 ], @connection.select_values("SELECT workspace_id FROM workspace_campfire_rooms ORDER BY workspace_id"), "Team's hold went with it"
    @connection.execute("DELETE FROM workspace_memberships WHERE user_id = 1")
    @connection.execute("DELETE FROM users WHERE id = 1")
    assert_equal [ 2 ], @connection.select_values("SELECT id FROM campfire_rooms ORDER BY id"), "Maya's old holds went with her"
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
