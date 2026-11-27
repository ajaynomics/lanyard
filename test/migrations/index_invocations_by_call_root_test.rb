require "test_helper"
require Rails.root.join("db/migrate/20261125051000_index_invocations_by_call_root")

class IndexInvocationsByCallRootTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "indexes the root of existing calls without changing their ids" do
    conn = Scratch.establish_connection(adapter: "sqlite3", database: ":memory:").lease_connection
    conn.create_table(:invocations) do |t|
      t.integer :conversation_id
      t.string :call_id
    end
    conn.execute("INSERT INTO invocations (conversation_id, call_id) VALUES (1, 'script'), (1, 'script/step')")

    migration = IndexInvocationsByCallRoot.new
    migration.suppress_messages { migration.exec_migration(conn, :up) }

    assert conn.index_name_exists?(:invocations, "index_invocations_on_conversation_id_and_call_root")
    assert_equal %w[ script script/step ], conn.select_values("SELECT call_id FROM invocations ORDER BY id")
  ensure
    Scratch.remove_connection
  end
end
