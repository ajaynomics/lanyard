require "test_helper"
require_relative "../../db/migrate/20261119170000_create_google_account_starts"

class GoogleAccountStartsMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "adding and removing the attempt table leaves existing users, grants and ordinary state alone" do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    Scratch.with_connection do |db|
      db.create_table(:mcp_servers) do |t|
        t.text :oauth_client
        t.text :oauth_tokens
        t.text :oauth_state
        t.text :oauth_pending
        t.boolean :enabled
      end
      db.create_table(:users) { |t| t.string :oidc_sub }
      db.execute "INSERT INTO users (oidc_sub) VALUES ('synthetic-subject')"
      db.execute "INSERT INTO mcp_servers (oauth_client, oauth_tokens, oauth_state, oauth_pending, enabled) VALUES ('client ciphertext', 'grant ciphertext', 'existing state', 'pending ciphertext', 0)"
      before = db.select_rows("SELECT * FROM mcp_servers")
      users = db.select_rows("SELECT * FROM users")
      migration = CreateGoogleAccountStarts.new
      migration.suppress_messages { migration.exec_migration(db, :up) }
      assert_equal before, db.select_rows("SELECT * FROM mcp_servers")
      assert_equal users, db.select_rows("SELECT * FROM users")
      assert_equal 0, db.select_value("SELECT COUNT(*) FROM google_account_starts")
      migration.suppress_messages { migration.exec_migration(db, :down) }
      assert_not db.table_exists?(:google_account_starts)
      assert_equal before, db.select_rows("SELECT * FROM mcp_servers")
      assert_equal users, db.select_rows("SELECT * FROM users")
    end
  ensure
    Scratch.remove_connection
  end
end
