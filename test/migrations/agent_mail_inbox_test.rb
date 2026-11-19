require "test_helper"
require "tmpdir"

# 20261116120000 keeps where an agent's own inbox has been read to (#77).
# Additive: an existing account, and one saved by code from before during a
# rolling deploy, has never been read, so the first read starts at the box's
# newest message and wakes the agent for none of what is already there.
class AgentMailInboxMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116120000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("mail-inbox")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an existing account, and one saved by code from before, has never been read" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    [ 1, 2 ].each do |id|
      @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (#{id}, 1, 1, 'Agent #{id}', 'Help.', 'm', 'agent#{id}', '#{now}', '#{now}')")
    end
    insert_account(1, now)

    run_migrations { it == VERSION }

    insert_account(2, now)
    assert_equal [ [ 1, "imap.example.com", nil, 0, nil, nil ], [ 2, "imap.example.com", nil, 0, nil, nil ] ],
      @connection.select_rows("SELECT agent_id, imap_host, inbox_validity, inbox_last_uid, inbox_read_at, inbox_error FROM agent_mail_accounts ORDER BY agent_id")
  end

  private
    def insert_account(agent_id, now)
      @connection.execute("INSERT INTO agent_mail_accounts (agent_id, address, smtp_host, imap_host, vault_entry, created_at, updated_at) " \
        "VALUES (#{agent_id}, 'desk#{agent_id}@example.com', 'smtp.example.com', 'imap.example.com', 'Mailbox', '#{now}', '#{now}')")
    end

    def run_migrations
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, :up) }
      end
    end
end
