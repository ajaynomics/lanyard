require "test_helper"
require "tmpdir"

class AddParentToAgentsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261120030000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "the nullable reference leaves existing agents and their dependents intact" do
    Dir.mktmpdir("reporting-migration") do |directory|
      Scratch.establish_connection(adapter: "sqlite3", database: File.join(directory, "scratch.sqlite3"))
      connection = Scratch.lease_connection
      connection.execute("CREATE TABLE agents (id INTEGER PRIMARY KEY, workspace_id INTEGER NOT NULL, name TEXT)")
      connection.execute("CREATE TABLE conversations (id INTEGER PRIMARY KEY, agent_id INTEGER REFERENCES agents(id) ON DELETE CASCADE)")
      connection.execute("INSERT INTO agents VALUES (1, 1, 'Aster'), (2, 1, 'Rill')")
      connection.execute("INSERT INTO conversations VALUES (1, 1), (2, 2)")
      root_page = connection.select_value("SELECT rootpage FROM sqlite_master WHERE name = 'agents'")

      require Rails.root.join("db/migrate/#{VERSION}_add_parent_to_agents")
      AddParentToAgents.new.exec_migration(connection, :up)

      assert_equal [ [ 1, "Aster", nil ], [ 2, "Rill", nil ] ], connection.select_rows("SELECT id, name, parent_id FROM agents")
      assert_equal [ [ 1, 1 ], [ 2, 2 ] ], connection.select_rows("SELECT id, agent_id FROM conversations")
      assert_equal root_page, connection.select_value("SELECT rootpage FROM sqlite_master WHERE name = 'agents'")
      assert_includes connection.indexes("agents").map(&:columns), %w[ workspace_id parent_id ]
      assert_empty connection.foreign_keys("agents")
    ensure
      Scratch.remove_connection
    end
  end
end
