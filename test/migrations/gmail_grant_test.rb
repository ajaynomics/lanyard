require "test_helper"
require_relative "../../db/migrate/20261122145100_add_gmail_grant_to_mcp_servers"

class GmailGrantMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "adding Gmail grant storage leaves existing sign-ins and links unchanged and unbound" do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    Scratch.with_connection do |db|
      db.create_table(:mcp_servers) do |t|
        t.text :oauth_tokens
        t.text :oauth_client
        t.text :oauth_pending
        t.string :oauth_state
        t.boolean :enabled
      end
      db.create_table(:google_account_starts) do |t|
        t.integer :mcp_server_id
        t.string :target_digest
      end
      db.execute "INSERT INTO mcp_servers (oauth_tokens, oauth_client, oauth_pending, oauth_state, enabled) VALUES ('token ciphertext', 'client ciphertext', 'pending ciphertext', 'ordinary state', 0)"
      db.execute "INSERT INTO google_account_starts (mcp_server_id, target_digest) VALUES (1, 'legacy target digest')"
      connectors = db.select_all("SELECT * FROM mcp_servers").to_a
      starts = db.select_all("SELECT * FROM google_account_starts").to_a
      migration = AddGmailGrantToMcpServers.new

      migration.suppress_messages { migration.exec_migration(db, :up) }
      assert_equal connectors.map { it.merge("gmail_grant" => nil) }, db.select_all("SELECT * FROM mcp_servers").to_a
      assert_equal starts, db.select_all("SELECT * FROM google_account_starts").to_a

      migration.suppress_messages { migration.exec_migration(db, :down) }
      assert_equal connectors, db.select_all("SELECT * FROM mcp_servers").to_a
      assert_equal starts, db.select_all("SELECT * FROM google_account_starts").to_a
    end
  ensure
    Scratch.remove_connection
  end
end
