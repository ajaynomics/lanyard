require "test_helper"
require Rails.root.join("db/migrate/20261125190000_add_former_email_names_to_agents")

class FormerEmailNamesMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "existing agents, and one saved by code from before, have no former addresses" do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    db = Scratch.lease_connection
    db.create_table(:agents) { |t| t.string :email_name }
    db.execute("INSERT INTO agents (email_name) VALUES ('iris')")
    migration = AddFormerEmailNamesToAgents.new
    migration.suppress_messages { migration.exec_migration(db, :up) }
    db.execute("INSERT INTO agents (email_name) VALUES ('juno')")
    assert_equal [ [ "iris", "[]" ], [ "juno", "[]" ] ], db.select_rows("SELECT email_name, former_email_names FROM agents")
  ensure
    Scratch.remove_connection
  end
end
