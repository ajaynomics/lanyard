require "test_helper"
require_relative "../../db/migrate/20261119100000_pin_event_only_calendar_collections"

class PinnedCalendarCollectionsMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "existing writable homes and read-only servers stay in their legacy modes" do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    Scratch.with_connection do |db|
      db.create_table(:agent_calendar_servers) do |t|
        t.integer :agent_id, null: false
        t.string :url, null: false
        t.string :vault_entry, null: false
        t.boolean :read_only, default: false, null: false
      end
      db.execute <<~SQL
        INSERT INTO agent_calendar_servers (agent_id, url, vault_entry, read_only) VALUES
          (1, 'https://calendar.example.org/home/', 'Team calendar', 0),
          (1, 'https://another.example.org/home/', 'Shared calendar', 1)
      SQL
      before = db.select_rows("SELECT * FROM agent_calendar_servers ORDER BY id")
      migration = PinEventOnlyCalendarCollections.new
      migration.suppress_messages { migration.exec_migration(db, :up) }
      assert_equal before.map { |row| row + [ nil ] }, db.select_rows("SELECT * FROM agent_calendar_servers ORDER BY id")
    end
  ensure
    Scratch.remove_connection
  end
end
