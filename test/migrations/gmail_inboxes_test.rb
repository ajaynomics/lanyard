require "test_helper"

class GmailInboxesMigrationTest < ActiveSupport::TestCase
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  test "existing agents, mail accounts and connectors gain no inbox or receipts" do
    require_relative "../../db/migrate/20261120010000_create_gmail_inboxes"
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    Scratch.with_connection do |db|
      %i[ agents mcp_servers users agent_mail_accounts ].each do |table|
        db.create_table(table) { |t| t.string :example }
        db.execute "INSERT INTO #{table} (example) VALUES ('kept')"
      end

      migration = CreateGmailInboxes.new
      migration.suppress_messages { migration.exec_migration(db, :up) }
      %i[ agents mcp_servers users agent_mail_accounts ].each { |table| assert_equal "kept", db.select_value("SELECT example FROM #{table}") }
      assert_equal 0, db.select_value("SELECT COUNT(*) FROM agent_gmail_inboxes")
      assert_equal 0, db.select_value("SELECT COUNT(*) FROM agent_gmail_inbox_receipts")

      db.execute "INSERT INTO agent_gmail_inboxes (agent_id, mcp_server_id, enabled_by_id, mailbox, created_at, updated_at) VALUES (1, 1, 1, 'owner@example.com', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
      assert_equal 0, db.select_value("SELECT enabled FROM agent_gmail_inboxes")
      db.execute "INSERT INTO agent_gmail_inbox_receipts (gmail_inbox_id, mailbox, gmail_message_id) VALUES (1, 'owner@example.com', 'g-1')"
      db.execute "DELETE FROM mcp_servers WHERE id = 1"
      assert_equal 0, db.select_value("SELECT COUNT(*) FROM agent_gmail_inboxes")
      assert_equal 0, db.select_value("SELECT COUNT(*) FROM agent_gmail_inbox_receipts")

      migration.suppress_messages { migration.exec_migration(db, :down) }
      assert_not db.table_exists?(:agent_gmail_inboxes)
      assert_not db.table_exists?(:agent_gmail_inbox_receipts)
      assert_equal "kept", db.select_value("SELECT example FROM agent_mail_accounts")
    end
  ensure
    Scratch.remove_connection
  end
end
