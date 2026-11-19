require "test_helper"
require "tmpdir"

# 20261115070000 and 120000 rebuild agents, 160000 and 190000 mcp_servers.
# Inside a migration's transaction SQLite keeps foreign keys on, so dropping
# the old table emptied core_connectors and connector_moves, whose keys
# cascade from both (PayerRebuildMigrationTest has the mechanism). Each case
# loads a real install's schema of the time and takes it to today in one
# migrate, as `bin/rails db:migrate` runs migrations: each in a transaction
# unless it disables one.
class OlderRebuildsMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("older-rebuilds")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an install with core connectors and moves keeps them all the way to today" do
    load_schema "test/models/workspace/import/schema_20261115040000.rb"
    seed_people
    insert "agents", id: 2, user_id: 1, name: "Bo", instructions: "Help.", model: "m", email_name: "bo", mail_to_agent_id: 1
    insert "core_connectors", agent_id: 1, mcp_server_id: 1
    insert "connector_moves", agent_id: 1, mcp_server_id: 1, connector_name: "fizzy", reason: "found"

    run_migrations { it > 20261115040000 }

    assert_equal [ [ 1, 1 ] ], @connection.select_rows("SELECT agent_id, mcp_server_id FROM core_connectors")
    assert_equal [ [ 1, 1, "fizzy" ] ], @connection.select_rows("SELECT agent_id, mcp_server_id, connector_name FROM connector_moves")
    assert_equal [ [ 1, nil ], [ 2, 1 ] ], @connection.select_rows("SELECT id, mail_to_agent_id FROM agents ORDER BY id")
    assert_empty @connection.select_rows("PRAGMA foreign_key_check")
  end

  test "an install from before core connectors keeps the ones their migration fills, all the way to today" do
    load_schema "test/migrations/schemas/schema_20261112010000.rb"
    seed_people
    insert "mcp_servers", id: 2, user_id: 1, name: "notes", loaded: false

    # 20261112000000 was merged after this install's release, stamped before it.
    run_migrations { it > 20261112010000 || it == 20261112000000 }

    assert_equal [ [ 1, 1 ] ], @connection.select_rows("SELECT agent_id, mcp_server_id FROM core_connectors")
    assert_empty @connection.select_rows("PRAGMA foreign_key_check")
  end

  private
    def load_schema(path)
      body = Rails.root.join(path).read[/define\(version: \S+\) do\n(.*)^end/m, 1]
      Class.new(ActiveRecord::Migration[8.2]) { define_method(:change) { instance_eval(body) } }.new.tap do |schema|
        schema.verbose = false
        schema.exec_migration(@connection, :up)
      end
    end

    def seed_people
      insert "users", id: 1, oidc_sub: "sub-1", name: "Maya", email: "maya@example.com"
      insert "agents", id: 1, user_id: 1, name: "Ada", instructions: "Help.", model: "m", email_name: "ada"
      insert "mcp_servers", id: 1, user_id: 1, name: "fizzy", loaded: true
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
