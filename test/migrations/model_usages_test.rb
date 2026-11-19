require "test_helper"
require "tmpdir"

# 20261117080000–080200 add who pays (workspaces.payer_id), where each
# thread's count stands (conversations.metered_usage) and what calls used
# (model_usages). Existing rows change in nothing: no workspace has a payer,
# so the install pays as before; no thread has a count, so its history is
# never counted as new; nothing is recorded yet. Run on a database of its own
# built by the migrations before them.
class ModelUsagesMigrationTest < ActiveSupport::TestCase
  FIRST, LAST = 20261117080000, 20261117080200
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("model-usages")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    @connection.execute("PRAGMA foreign_keys = ON")
    run_migrations { it < FIRST }
    insert "users", id: 1, oidc_sub: "sub-1", name: "Maya", email: "maya@example.com"
    insert "workspaces", id: 1, personal: true
    insert "workspaces", id: 2, personal: false, name: "Team"
    insert "agents", id: 1, user_id: 1, workspace_id: 1, name: "Ada", instructions: "Help.", model: "m", email_name: "ada"
    insert "conversations", id: 1, user_id: 1, agent_id: 1, request_id: "r-1", listed_at: Time.current.utc.iso8601,
      usage: { totalTokens: 5_000 }.to_json
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing workspaces have no payer and existing threads no count, and nothing is recorded" do
    run_migrations { it.between?(FIRST, LAST) }

    assert_equal [ [ 1, nil ], [ 2, nil ] ], @connection.select_rows("SELECT id, payer_id FROM workspaces ORDER BY id")
    assert_equal [ [ 1, nil, { "totalTokens" => 5_000 }.to_json ] ], @connection.select_rows("SELECT id, metered_usage, usage FROM conversations")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM model_usages")
  end

  test "a record outlives its agent and thread, keeps the agent's name, and goes with its workspace" do
    run_migrations { it.between?(FIRST, LAST) }
    insert "model_usages", workspace_id: 1, agent_id: 1, agent_name: "Ada", conversation_id: 1, payer_id: 2, model: "m", input: 3, total_tokens: 3

    @connection.execute("DELETE FROM conversations")
    @connection.execute("DELETE FROM agents")
    assert_equal [ [ 1, nil, nil, "Ada", 2 ] ], @connection.select_rows("SELECT workspace_id, agent_id, conversation_id, agent_name, payer_id FROM model_usages")

    @connection.execute("DELETE FROM workspaces WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM model_usages")
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
