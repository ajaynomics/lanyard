require "test_helper"
require "tmpdir"

# 20261117080000 adds workspaces.payer_id with a foreign key, which SQLite can
# only do by rebuilding workspaces: copy it aside, drop it, copy it back. Rails
# turns foreign keys off around the rebuild, but SQLite ignores
# "PRAGMA foreign_keys = OFF" inside a transaction, and a migration runs in
# one; only the checks are deferred. So dropping the old table deletes its
# rows as far as the keys pointing at it know: a cascading child loses every
# row, a nullifying one has its column emptied, and a plain key, checked only
# at commit, passes. An install taking 20261117020000 to 080000 in one
# migrate lost every workspace's Campfire rooms, install connectors, contact
# routes, proposals, revisions and imports. Run as `bin/rails db:migrate`
# runs them: each in a transaction unless it disables one.
class PayerRebuildMigrationTest < ActiveSupport::TestCase
  BEFORE_NETWORKS, PAYER = 20261117020000, 20261117080000
  CASCADING = %w[ workspace_campfire_rooms workspace_install_connectors workspace_contact_routes
    workspace_proposals workspace_revisions workspace_imports ]
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("payer-rebuild")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < BEFORE_NETWORKS }
    insert "users", id: 1, oidc_sub: "sub-1", name: "Maya", email: "maya@example.com"
    insert "workspaces", id: 1, personal: true
    insert "workspace_memberships", workspace_id: 1, user_id: 1
    insert "agents", id: 1, user_id: 1, workspace_id: 1, name: "Ada", instructions: "Help.", model: "m", email_name: "ada"
    insert "campfire_rooms", user_id: 1, room_id: 7, relayed_at: "[]"
    insert "workspace_install_connectors", workspace_id: 1, name: "fizzy", api_key: "made-up-key"
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a workspace's rows in every cascading table survive taking the networks through the payer in one migrate" do
    run_migrations { it.between?(BEFORE_NETWORKS, PAYER - 1) }
    seed_children
    assert_equal CASCADING.index_with(1), counts

    run_migrations { it == PAYER }

    assert_equal CASCADING.index_with(1), counts
    assert_equal [ [ 1, nil ] ], @connection.select_rows("SELECT id, payer_id FROM workspaces")
    assert_equal 1, @connection.select_value("PRAGMA foreign_keys")
    assert_empty @connection.select_rows("PRAGMA foreign_key_check")
  end

  test "the rebuild inside a transaction empties cascading children, nulls nullifying ones and keeps plain ones" do
    run_migrations { it.between?(BEFORE_NETWORKS, PAYER - 1) }
    seed_children
    @connection.execute("CREATE TABLE nullifying_children (id INTEGER PRIMARY KEY, workspace_id INTEGER REFERENCES workspaces (id) ON DELETE SET NULL)")
    @connection.execute("INSERT INTO nullifying_children (id, workspace_id) VALUES (1, 1)")

    @connection.transaction do
      @connection.execute("PRAGMA foreign_keys = OFF")
      assert_equal 1, @connection.select_value("PRAGMA foreign_keys"), "SQLite ignores the pragma inside a transaction"
      @connection.add_reference :workspaces, :payer, foreign_key: { to_table: :workspaces, on_delete: :nullify }
    end

    assert_equal CASCADING.index_with(0), counts
    assert_equal [ [ 1, nil ] ], @connection.select_rows("SELECT id, workspace_id FROM nullifying_children")
    assert_equal [ [ 1, 1 ] ], @connection.select_rows("SELECT id, workspace_id FROM agents")
    assert_equal 1, @connection.select_value("SELECT COUNT(*) FROM workspace_memberships")
  end

  private
    def seed_children
      insert "workspace_contact_routes", workspace_id: 1, agent_id: 1, contact: "+15550100"
      insert "workspace_proposals", workspace_id: 1, proposed_by_id: 1, instructions: "Be brief."
      insert "workspace_revisions", workspace_id: 1, instructions: "Be brief.", changed_by_id: 1
      insert "workspace_imports", workspace_id: 1, source_digest: "d-1", source_version: "v1"
    end

    def counts
      CASCADING.index_with { @connection.select_value("SELECT COUNT(*) FROM #{it}") }
    end

    def run_migrations
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        migration = class_name.constantize.new(class_name, version.to_i)
        if migration.disable_ddl_transaction
          migration.exec_migration(@connection, :up)
        else
          @connection.transaction { migration.exec_migration(@connection, :up) }
        end
      end
    end

    def insert(table, **values)
      now = Time.current.utc.iso8601
      columns = @connection.columns(table).map(&:name)
      values = { created_at: now, updated_at: now }.select { |column, _| columns.include?(column.to_s) }.merge(values)
      @connection.execute("INSERT INTO #{table} (#{values.keys.join(', ')}) VALUES (#{values.values.map { @connection.quote(it) }.join(', ')})")
    end
end
