require "test_helper"
require "tmpdir"

# 20261116180000 lets an agent read mailboxes and calendars it never writes
# to, beside its own (docs/email.md, "Read-only mailboxes"). Every existing
# account and calendar server stays the one the agent sends and writes
# through, as does one saved by code from before during a rolling deploy; a
# second sending one is still refused, by the database now, and read-only ones
# may sit beside it. Run on a database of its own built by the migrations
# before it, then its own.
class ReadOnlyMailboxesMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116180000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("read-only-mailboxes")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an existing account and calendar server stay the sending ones; a second sending one is refused, read-only ones are not" do
    @now = Time.current.utc.iso8601
    execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{@now}', '#{@now}')")
    execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{@now}', '#{@now}')")
    [ 1, 2 ].each do |id|
      execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (#{id}, 1, 1, 'Agent #{id}', 'Help.', 'm', 'agent#{id}', '#{@now}', '#{@now}')")
    end
    account(1, "desk1@example.com", inbox_last_uid: 5)
    calendar(1, "https://dav.example.com/calendars/desk1/")

    run_migrations { it == VERSION }

    # Saved by code from before, which names no read_only.
    account(2, "desk2@example.com")
    calendar(2, "https://dav.example.com/calendars/desk2/")
    assert_equal [ [ 1, "desk1@example.com", 0, 5 ], [ 2, "desk2@example.com", 0, 0 ] ],
      @connection.select_rows("SELECT agent_id, address, read_only, inbox_last_uid FROM agent_mail_accounts ORDER BY agent_id")
    assert_equal [ [ 1, 0 ], [ 2, 0 ] ], @connection.select_rows("SELECT agent_id, read_only FROM agent_calendar_servers ORDER BY agent_id")

    assert_raises(ActiveRecord::RecordNotUnique) { account(1, "another@example.com") }
    assert_raises(ActiveRecord::RecordNotUnique) { calendar(1, "https://dav.example.com/calendars/another/") }
    execute("INSERT INTO agent_mail_accounts (agent_id, address, imap_host, vault_entry, read_only, created_at, updated_at) " \
      "VALUES (1, 'old@example.com', 'imap.old.example.com', 'Old', 1, '#{@now}', '#{@now}')")
    execute("INSERT INTO agent_calendar_servers (agent_id, url, vault_entry, read_only, created_at, updated_at) " \
      "VALUES (1, 'https://dav.old.example.com/calendars/old/', 'Old', 1, '#{@now}', '#{@now}')")
    assert_equal 2, @connection.select_value("SELECT COUNT(*) FROM agent_mail_accounts WHERE agent_id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM agent_mail_account_folders")
  end

  private
    def execute(sql) = @connection.execute(sql)

    def account(agent_id, address, inbox_last_uid: 0)
      execute("INSERT INTO agent_mail_accounts (agent_id, address, smtp_host, imap_host, vault_entry, inbox_last_uid, created_at, updated_at) " \
        "VALUES (#{agent_id}, '#{address}', 'smtp.example.com', 'imap.example.com', 'Mailbox', #{inbox_last_uid}, '#{@now}', '#{@now}')")
    end

    def calendar(agent_id, url)
      execute("INSERT INTO agent_calendar_servers (agent_id, url, vault_entry, created_at, updated_at) VALUES (#{agent_id}, '#{url}', 'Calendar', '#{@now}', '#{@now}')")
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
