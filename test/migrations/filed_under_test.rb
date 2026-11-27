require "test_helper"
require "tmpdir"

# 20261120020000 adds the file a run's work is filed under (#277) to threads,
# helpers and what calls used. Existing rows change in nothing: each has no
# file, so all usage recorded before counts as untagged. Run on a database of
# its own built by the migrations before it.
class FiledUnderMigrationTest < ActiveSupport::TestCase
  VERSION = 20261120020000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("filed-under")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    @connection.execute("PRAGMA foreign_keys = ON")
    run_migrations { it < VERSION }
    insert "users", id: 1, oidc_sub: "sub-1", name: "Maya", email: "maya@example.com"
    insert "workspaces", id: 1, personal: true
    insert "agents", id: 1, user_id: 1, workspace_id: 1, name: "Ada", instructions: "Help.", model: "m", email_name: "ada"
    insert "conversations", id: 1, user_id: 1, agent_id: 1, request_id: "r-1", listed_at: Time.current.utc.iso8601
    insert "helpers", id: 1, conversation_id: 1, call_id: "toolu_h", task: "Look it up"
    insert "model_usages", id: 1, workspace_id: 1, agent_id: 1, agent_name: "Ada", conversation_id: 1, model: "m", input: 3, total_tokens: 3
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing threads, helpers and usage are filed under nothing" do
    run_migrations { it == VERSION }

    %w[ conversations helpers model_usages ].each do |table|
      assert_equal [ [ 1, nil ] ], @connection.select_rows("SELECT id, filed_under FROM #{table}"), table
    end
    assert_equal [ [ 1, "Ada", 3 ] ], @connection.select_rows("SELECT id, agent_name, total_tokens FROM model_usages")
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
