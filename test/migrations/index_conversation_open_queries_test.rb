require "test_helper"
require Rails.root.join("db/migrate/20261125050000_index_conversation_open_queries")

class IndexConversationOpenQueriesTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @conn = Scratch.establish_connection(adapter: "sqlite3", database: ":memory:").lease_connection
    @conn.create_table(:invocations) { |t| t.string :state; t.datetime :expires_at }
    @conn.create_table(:messages) do |t|
      t.integer :conversation_id
      t.integer :entry_id
      t.string :role
      t.json :tool_calls, default: []
      t.datetime :created_at
    end
    @conn.add_index :messages, [ :conversation_id, :entry_id ]
    @conn.add_index :messages, :conversation_id
  end

  teardown { Scratch.remove_connection }

  test "the indexes preserve existing invocations and messages" do
    @conn.execute("INSERT INTO invocations (state, expires_at) VALUES ('awaiting_person', '2026-11-24 12:00:00')")
    @conn.execute("INSERT INTO messages (conversation_id, entry_id, role, created_at) VALUES (1, 1, 'summary', '2026-11-23 12:00:00')")
    before = [ @conn.select_rows("SELECT * FROM invocations"), @conn.select_rows("SELECT * FROM messages") ]

    migrate

    assert @conn.index_exists?(:invocations, [ :state, :expires_at ])
    assert @conn.index_exists?(:messages, [ :conversation_id, :created_at ], where: "role = 'summary'")
    assert_equal before, [ @conn.select_rows("SELECT * FROM invocations"), @conn.select_rows("SELECT * FROM messages") ]
  end

  # Opening a thread asks for its newest answer. With stats from ANALYZE, an
  # index over every role tempted SQLite to collect a long thread's replies and
  # sort them; only the summaries are indexed, so it still walks back by entry.
  test "a long thread's newest answer still walks back by entry after ANALYZE" do
    @conn.execute(<<~SQL)
      INSERT INTO messages (conversation_id, entry_id, role, tool_calls, created_at)
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 6000)
      SELECT 1 + i / 3000, i, CASE WHEN i % 997 = 0 THEN 'summary' WHEN i % 5 IN (1, 2) THEN 'assistant' ELSE 'user' END,
        CASE WHEN i % 5 = 1 THEN '[{"id":"c"}]' ELSE '[]' END, datetime('now', '-' || (6000 - i) || ' seconds')
      FROM n
    SQL
    migrate
    @conn.execute("ANALYZE")

    conversation = Conversation.new(id: 1)
    assert_equal [ "SEARCH messages USING INDEX index_messages_on_conversation_id_and_entry_id (conversation_id=?)" ],
      plan(conversation.messages.answers.order(entry_id: :desc, id: :desc).limit(1))
    assert_match "index_messages_on_conversation_id_and_created_at",
      plan(conversation.messages.where(role: "summary").select("MAX(created_at)")).join
  end

  private
    def migrate
      migration = IndexConversationOpenQueries.new
      migration.suppress_messages { migration.exec_migration(@conn, :up) }
    end

    def plan(relation) = @conn.select_rows("EXPLAIN QUERY PLAN #{relation.to_sql}").map(&:last)
end
