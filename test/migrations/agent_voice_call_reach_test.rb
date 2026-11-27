require "test_helper"
require Rails.root.join("db/migrate/20261126150000_add_reach_to_agent_voice_calls")

class AgentVoiceCallReachMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "calls recorded before reach existed are strangers', so none reaches the thread after the fact" do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    db = Scratch.lease_connection
    db.create_table(:agent_voice_calls) { |t| t.string :session_id }
    db.execute("INSERT INTO agent_voice_calls (session_id) VALUES ('live_old')")
    migration = AddReachToAgentVoiceCalls.new
    migration.suppress_messages { migration.exec_migration(db, :up) }
    assert_equal [ [ "live_old", "stranger" ] ], db.select_rows("SELECT session_id, reach FROM agent_voice_calls")
    migration.suppress_messages { migration.exec_migration(db, :down) }
    assert_equal [ [ "live_old" ] ], db.select_rows("SELECT * FROM agent_voice_calls").map { it.drop(1) }
  ensure
    Scratch.remove_connection
  end
end
