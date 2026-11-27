require "test_helper"
require_relative "../../db/migrate/20261119110000_create_mcp_client_secret_setups"

class McpClientSecretSetupsMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "existing connector credentials remain untouched and no links are issued by migration" do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    Scratch.with_connection do |db|
      db.create_table(:mcp_servers) { |t| t.text :oauth_client }
      db.create_table(:users)
      db.execute "INSERT INTO mcp_servers (oauth_client) VALUES ('example ciphertext')"
      before = db.select_rows("SELECT * FROM mcp_servers")
      migration = CreateMcpClientSecretSetups.new
      migration.suppress_messages { migration.exec_migration(db, :up) }
      assert_equal before, db.select_rows("SELECT * FROM mcp_servers")
      assert_equal 0, db.select_value("SELECT COUNT(*) FROM mcp_client_secret_setups")
    end
  ensure
    Scratch.remove_connection
  end
end
