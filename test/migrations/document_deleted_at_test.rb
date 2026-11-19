require "test_helper"
require "tmpdir"

# 20261118230000 lets a document be deleted softly (Document::Deletable).
# Additive: every document there stays undeleted and listed, and a document
# made by code from before, during a rolling deploy, is undeleted too. A
# title stays unique among the undeleted. Run on a database of its own built
# by the migrations before it.
class DocumentDeletedAtTest < ActiveSupport::TestCase
  VERSION = 20261118230000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("document-deleted-at")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing documents, and one made by code from before, stay undeleted, their titles still unique" do
    insert "users", id: 1, oidc_sub: "s", name: "Maya", email: "maya@example.com"
    insert "workspaces", id: 1, personal: true
    insert "agents", id: 1, user_id: 1, workspace_id: 1, name: "Iris", instructions: "Help.", model: "m", email_name: "iris"
    insert "documents", id: 1, agent_id: 1, title: "Trip plan"
    insert "document_versions", document_id: 1, number: 1, body: "Day 1", author: "agent"

    run_migrations { it == VERSION }

    assert_equal [ [ 1, "Trip plan", nil, nil ] ], @connection.select_rows("SELECT id, title, deleted_at, deleted_by FROM documents")
    assert_equal [ [ 1, "Day 1" ] ], @connection.select_rows("SELECT document_id, body FROM document_versions")
    insert "documents", id: 2, agent_id: 1, title: "Packing"
    assert_equal [ nil, nil ], @connection.select_rows("SELECT deleted_at, deleted_by FROM documents WHERE id = 2").sole
    assert_raises(ActiveRecord::RecordNotUnique) { insert "documents", id: 3, agent_id: 1, title: "Trip plan" }

    @connection.execute("UPDATE documents SET deleted_at = '2026-11-18 00:00:00', deleted_by = 'person' WHERE id = 1")
    insert "documents", id: 4, agent_id: 1, title: "Trip plan"
    assert_equal 2, @connection.select_value("SELECT COUNT(*) FROM documents WHERE title = 'Trip plan'")
  end

  private
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
