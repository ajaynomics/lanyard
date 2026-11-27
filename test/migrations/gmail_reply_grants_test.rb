require "test_helper"

class GmailReplyGrantsMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "existing connectors, agents and calls gain no reply grants or audit entries" do
    require_relative "../../db/migrate/20261121120000_create_gmail_reply_grants"
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    Scratch.with_connection do |db|
      %i[ mcp_servers agents invocations ].each do |table|
        db.create_table(table) { |t| t.string :example }
        db.execute "INSERT INTO #{table} (example) VALUES ('kept')"
      end

      migration = CreateGmailReplyGrants.new
      migration.suppress_messages { migration.exec_migration(db, :up) }
      %i[ mcp_servers agents invocations ].each { |table| assert_equal "kept", db.select_value("SELECT example FROM #{table}") }
      assert_equal 0, db.select_value("SELECT COUNT(*) FROM gmail_reply_grants")
      assert_equal [ nil, nil ], db.select_rows("SELECT checking_gmail_reply_grant_id, gmail_reply_grant_address FROM invocations").sole
      db.execute "INSERT INTO gmail_reply_grants (mcp_server_id, agent_id, address, created_at, updated_at) VALUES (1, 1, 'pat@example.net', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
      db.execute "DELETE FROM mcp_servers WHERE id = 1"
      assert_equal 0, db.select_value("SELECT COUNT(*) FROM gmail_reply_grants")

      migration.suppress_messages { migration.exec_migration(db, :down) }
      assert_not db.table_exists?(:gmail_reply_grants)
      assert_equal %w[ id example ], db.columns(:invocations).map(&:name)
      assert_equal "kept", db.select_value("SELECT example FROM invocations")
    end
  ensure
    Scratch.remove_connection
  end
end
