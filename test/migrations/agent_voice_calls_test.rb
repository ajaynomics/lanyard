require "test_helper"
require Rails.root.join("db/migrate/20261123232100_create_agent_voice_calls")

class AgentVoiceCallsMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "the additive migration preserves existing agents and leaves their receipts empty" do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    db = Scratch.lease_connection
    db.create_table(:agents) { |t| t.string :name }
    db.execute("INSERT INTO agents (name) VALUES ('Existing')")
    migration = CreateAgentVoiceCalls.new
    migration.suppress_messages { migration.exec_migration(db, :up) }
    assert_empty db.select_rows("SELECT id FROM agent_voice_calls")
    assert_equal %w[ delivery_id event_id session_id ], db.indexes(:agent_voice_calls).select(&:unique).flat_map(&:columns).sort
    assert_equal :nullify, db.foreign_keys(:agent_voice_calls).sole.on_delete
    migration.suppress_messages { migration.exec_migration(db, :down) }
    refute db.table_exists?(:agent_voice_calls)
    assert_equal [ [ 1, "Existing" ] ], db.select_rows("SELECT id, name FROM agents")
  ensure
    Scratch.remove_connection
  end
end
