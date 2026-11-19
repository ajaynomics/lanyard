require "test_helper"
require "tmpdir"

# 20261115000000 makes a person's connectors core or lookup for each agent.
# Every agent keeps as core exactly the connectors of its person that were
# loaded, so what each declares, and how many, is what it was: Agent#core?
# reads these rows where it read mcp_servers.loaded. No agent keeps a found
# tool from then on unless the person says so, and the tables go again on the
# way down. Run on a database of its own built by the migrations before it.
class CoreConnectorsTest < ActiveSupport::TestCase
  VERSION = 20261115000000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("core_connectors")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "each agent keeps as core every connector of its person that was loaded, and nothing else; down drops the tables" do
    now = Time.current.utc.iso8601
    insert = ->(sql) { @connection.execute(sql) }
    insert.("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's1', 'Maya', 'maya@example.com', '#{now}', '#{now}'), " \
      "(2, 's2', 'Sam', 'sam@example.com', '#{now}', '#{now}')")
    insert.("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) VALUES " \
      "(1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}'), (2, 1, 'Robin', 'Help.', 'm', 'robin', '#{now}', '#{now}'), " \
      "(3, 2, 'Ada', 'Help.', 'm', 'ada', '#{now}', '#{now}')")
    insert.("INSERT INTO conversations (id, user_id, agent_id, request_id, title, status, listed_at, created_at, updated_at) VALUES " \
      "(1, 1, 1, 'r', 'Thread', 'idle', '#{now}', '#{now}', '#{now}')")
    # Robin had already kept a tool it found; Ada's thread found none.
    insert.("INSERT INTO conversations (id, user_id, agent_id, request_id, title, status, listed_at, activated_tools, created_at, updated_at) VALUES " \
      "(2, 1, 2, 'r2', 'Thread', 'idle', '#{now}', '[\"mcp__crm__find\"]', '#{now}', '#{now}'), " \
      "(3, 2, 3, 'r3', 'Thread', 'idle', '#{now}', '[]', '#{now}', '#{now}')")
    connector = ->(id, user, name, loaded:, enabled: 1, conversation: "NULL") do
      insert.("INSERT INTO mcp_servers (id, user_id, conversation_id, name, url, loaded, enabled, created_at, updated_at) VALUES " \
        "(#{id}, #{user}, #{conversation}, '#{name}', 'https://#{name}.example.com/mcp', #{loaded}, #{enabled}, '#{now}', '#{now}')")
    end
    connector.(1, 1, "wiki", loaded: 1)
    connector.(2, 1, "crm", loaded: 0)
    connector.(3, 1, "chat", loaded: 1, enabled: 0)
    connector.(4, 1, "notes", loaded: 1, conversation: 1)
    connector.(5, 2, "wiki", loaded: 1)
    loaded_before = @connection.select_rows("SELECT agents.id, mcp_servers.id FROM agents JOIN mcp_servers ON mcp_servers.user_id = agents.user_id " \
      "WHERE mcp_servers.conversation_id IS NULL AND mcp_servers.loaded = 1 ORDER BY 1, 2")

    run_migrations(:up) { it == VERSION }

    cores = @connection.select_rows("SELECT agent_id, mcp_server_id FROM core_connectors ORDER BY 1, 2")
    assert_equal [ [ 1, 1 ], [ 1, 3 ], [ 2, 1 ], [ 2, 3 ], [ 3, 5 ] ], cores,
      "each agent its own person's loaded ones, a switched-off one too so it comes back as it was; never a conversation's own or another person's"
    assert_equal loaded_before, cores, "so no agent's declared count changes"
    assert_equal [ 1, 0, 1, 1, 1 ], @connection.select_values("SELECT loaded FROM mcp_servers ORDER BY id"), "the column stays for the release still running"
    assert_equal [ 0, 1, 0 ], @connection.select_values("SELECT promotes_found_tools FROM agents ORDER BY id"),
      "an agent that kept a found tool goes on keeping it, so nothing it declares changes at deploy"
    assert_empty @connection.select_rows("SELECT * FROM connector_moves")
    assert_equal [ nil ] * 5, @connection.select_values("SELECT install_core FROM mcp_servers ORDER BY id"), "no install word applied yet"

    insert.("INSERT INTO mcp_servers (id, user_id, name, url, created_at, updated_at) VALUES (6, 1, 'docs', 'https://docs.example.com/mcp', '#{now}', '#{now}')")
    assert_equal 5, @connection.select_value("SELECT COUNT(*) FROM core_connectors"), "a connector added later is core for no agent"
    insert.("DELETE FROM mcp_servers WHERE id = 1")
    assert_equal [ [ 1, 3 ], [ 2, 3 ], [ 3, 5 ] ], @connection.select_rows("SELECT agent_id, mcp_server_id FROM core_connectors ORDER BY 1, 2"),
      "removing a connector removes it from every agent's core"

    run_migrations(:down) { it == VERSION }
    assert_not @connection.table_exists?(:core_connectors)
    assert_not @connection.table_exists?(:connector_moves)
    assert_not_includes @connection.columns(:agents).map(&:name), "promotes_found_tools"
    assert_not_includes @connection.columns(:mcp_servers).map(&:name), "install_core"
    assert_equal [ 2, 3, 4, 5, 6 ], @connection.select_values("SELECT id FROM mcp_servers ORDER BY id")
  end

  private
    def run_migrations(direction)
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, direction) }
      end
    end
end
