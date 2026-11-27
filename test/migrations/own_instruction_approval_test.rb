require "test_helper"
require_relative "../../db/migrate/20261123220000_add_own_instruction_approval"

class OwnInstructionApprovalMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "existing agents and workspaces inherit without rewriting the old worker's flag" do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = Scratch.lease_connection
    connection.create_table(:agents) { |table| table.boolean :asks_every_instruction_change, default: true, null: false }
    connection.create_table(:workspaces)
    connection.execute("INSERT INTO agents (asks_every_instruction_change) VALUES (1), (0)")
    connection.execute("INSERT INTO workspaces DEFAULT VALUES")

    ActiveRecord::Migration.suppress_messages { AddOwnInstructionApproval.new.exec_migration(connection, :up) }

    assert_equal [ [ 1, nil ], [ 0, nil ] ],
      connection.select_rows("SELECT asks_every_instruction_change, own_instruction_approval FROM agents ORDER BY id")
    assert_nil connection.select_value("SELECT own_instruction_approval FROM workspaces")
    connection.execute("INSERT INTO agents DEFAULT VALUES")
    assert_equal [ [ 1, nil ] ],
      connection.select_rows("SELECT asks_every_instruction_change, own_instruction_approval FROM agents WHERE id = 3")
  ensure
    Scratch.remove_connection
  end
end
