require "test_helper"
require "tmpdir"

# 20261107210000 renames the assistant's tables and columns on a database that
# already holds people's data (staging). Nothing may be lost, every foreign key
# must follow the new name, and a rollback must put it all back. The test builds
# the schema staging had by running the migrations before the rename into a
# database of its own (never the test database), fills it, and migrates.
class RenameBotsToAgentsTest < ActiveSupport::TestCase
  VERSION = 20261107210000

  # Nothing here touches the test database, so there is no transaction to wrap.
  self.use_transactional_tests = false

  # A pool of its own: the migrations run on this connection, not Active Record's.
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  RENAMED = { "bots" => "agents", "bot_revisions" => "agent_revisions" }.freeze
  OWNED = %w[ agent_revisions computers concourse_agents conversations mcp_servers notes prompts skills ].freeze

  setup do
    @verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    @directory = Dir.mktmpdir("rename-bots")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    fill
    @before = dump
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "every row survives with its values, and the sidecar's ids keep counting" do
    run_migrations(:up) { it == VERSION }

    assert RENAMED.values.all? { @connection.table_exists?(it) }
    assert RENAMED.keys.none? { @connection.table_exists?(it) }
    # Free text that says "Bot" (a message here) is history, and stays as written.
    assert_equal @before.transform_keys { RENAMED.fetch(it, it) }, dump
    assert_equal [ [ 1, 1 ] ], @connection.select_rows("SELECT id, user_id FROM agents")
    assert_equal [ 1, 1, 1 ], @connection.select_values("SELECT agent_id FROM conversations ORDER BY id")
    assert_equal [ 1 ], @connection.select_values("SELECT agent_id FROM mcp_servers WHERE conversation_id IS NOT NULL")

    insert "agents", user_id: 1, name: "Second", instructions: "x", model: "m"
    assert_equal 2, @connection.select_value("SELECT MAX(id) FROM agents"), "a new agent takes the next id"
  end

  test "every foreign key follows the new name and is still enforced" do
    run_migrations(:up) { it == VERSION }

    assert_empty @connection.select_rows("PRAGMA foreign_key_check")
    OWNED.each do |table|
      assert_equal [ [ "agents", "agent_id" ] ], @connection.foreign_keys(table).filter_map { [ it.to_table, it.column ] if it.to_table == "agents" },
        "#{table} refers to agents by agent_id"
    end
    assert_equal [ "users" ], @connection.foreign_keys("agents").map(&:to_table)

    assert_raises(ActiveRecord::InvalidForeignKey) { insert "conversations", user_id: 1, agent_id: 99, request_id: "x", durable_id: "x" }
    assert_raises(ActiveRecord::InvalidForeignKey) { @connection.execute("DELETE FROM agents WHERE id = 1") }
  end

  test "no table, column or index keeps the old name, and indexes carry the new one" do
    run_migrations(:up) { it == VERSION }

    leftovers = @connection.select_rows("SELECT name, sql FROM sqlite_master").select { |name, sql| "#{name} #{sql}".match?(/(?<![a-z])bots?(?![a-z])/i) }
    assert_empty leftovers.map(&:first)
    assert_includes @connection.indexes("agents").map(&:name), "index_agents_on_user_id"
    assert_includes @connection.indexes("agent_revisions").map(&:name), "index_agent_revisions_on_agent_id"
    assert_includes @connection.indexes("conversations").map(&:name), "index_conversations_on_agent_id_and_durable_id"
    assert_includes @connection.indexes("notes").map(&:name), "index_notes_on_agent_id_and_key"
    assert_includes @connection.indexes("skills").map(&:name), "index_skills_on_agent_id_and_name"
    assert @connection.indexes("computers").find { it.name == "index_computers_on_agent_id" }.unique
  end

  test "a rollback puts back the old names with every row" do
    run_migrations(:up) { it == VERSION }
    run_migrations(:down) { it == VERSION }

    assert_equal @before, dump
    assert_empty @connection.select_rows("PRAGMA foreign_key_check")
    assert @connection.column_exists?("conversations", :bot_id)
    assert_includes @connection.indexes("conversations").map(&:name), "index_conversations_on_bot_id_and_durable_id"
  end

  private
    # The migrations are run as the migrator would, one transaction each, but on
    # the scratch connection; `exec_migration` is what it calls inside.
    def run_migrations(direction)
      files = Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }
      files = files.reverse if direction == :down
      files.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize # ".active_storage" is the scope of one
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        migration = class_name.constantize.new(class_name, version.to_i)
        @connection.transaction { migration.exec_migration(@connection, direction) }
      end
    end

    def insert(table, **values)
      now = Time.current.utc.iso8601
      columns = @connection.columns(table).map(&:name)
      values = { created_at: now, updated_at: now }.select { |column, _| columns.include?(column.to_s) }.merge(values)
      @connection.execute("INSERT INTO #{table} (#{values.keys.join(', ')}) VALUES (#{values.values.map { @connection.quote(it) }.join(', ')})")
    end

    # One person with one assistant that has everything: a conversation (and a
    # branch of it), messages, a computer, revisions, notes, skills, prompts,
    # connectors, a Concourse identity and a peer task.
    def fill
      insert "users", id: 1, oidc_sub: "sub-1", name: "Maya", email: "m@example.com"
      insert "bots", id: 1, user_id: 1, name: "Robin", instructions: "Help.", model: "anthropic/claude", tool_names: '["current_time"]'
      insert "bot_revisions", bot_id: 1, instructions: "Help.", model: "anthropic/claude", skills: '[{"name":"trip","description":"d","body":"b"}]'
      insert "computers", bot_id: 1, name: "acme-staging-b1"
      insert "concourse_agents", bot_id: 1, organization: "acme", handle: "acme/robin", client_id: "c", client_secret: "s"
      insert "conversations", id: 1, user_id: 1, bot_id: 1, request_id: "r1", durable_id: "d1", title: "Lisbon"
      insert "conversations", id: 2, user_id: 1, bot_id: 1, request_id: "r2", durable_id: "d2", parent_id: 1, root_id: 1
      insert "conversations", id: 3, user_id: 1, bot_id: 1, request_id: "r3", durable_id: "d3"
      3.times { |n| insert "messages", conversation_id: 1, entry_key: "k#{n}", entry_id: n, role: "user", content: "Is this a Bot or a person?" }
      insert "invocations", conversation_id: 1, task_id: "t", call_id: "c", tool_name: "current_time", digest: "d"
      insert "peer_tasks", conversation_id: 1, task_id: "p1", peer: "acme/friend", direction: "inbound", state: "working"
      insert "notes", bot_id: 1, key: "k", body: "remember this"
      insert "skills", bot_id: 1, name: "trip", description: "Plans trips.", body: "Steps"
      insert "prompts", bot_id: 1, name: "review", body: "Review $1"
      insert "mcp_servers", bot_id: 1, user_id: 1, name: "wiki", url: "https://mcp.example.test/mcp"
      insert "mcp_servers", bot_id: 1, user_id: 1, name: "mine", url: "https://mcp.example.test/mine", conversation_id: 1
    end

    # Every table's rows, in id order, as the database stores them.
    def dump
      tables = @connection.tables - %w[ schema_migrations ar_internal_metadata ]
      tables.sort.index_with { @connection.select_rows("SELECT * FROM #{it} ORDER BY id") }
    end
end
