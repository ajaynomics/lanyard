require "test_helper"
require "tmpdir"

# 20261116200000 lets an owner make an agent's own mail account its only
# address (docs/email.md, "Its only address"). Every existing account, and one
# saved by code from before during a rolling deploy, stays as it was: not the
# only address, so the agent keeps its address here too. Run on a database of
# its own built by the migrations before it, then its own.
class PrimaryMailAccountMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116200000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("primary-mail-account")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing accounts, sending and read only, and one saved by code from before are not the only address" do
    @now = Time.current.utc.iso8601
    execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{@now}', '#{@now}')")
    execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{@now}', '#{@now}')")
    [ 1, 2 ].each do |id|
      execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (#{id}, 1, 1, 'Agent #{id}', 'Help.', 'm', 'agent#{id}', '#{@now}', '#{@now}')")
    end
    account(1, "desk1@example.com")
    execute("INSERT INTO agent_mail_accounts (agent_id, address, imap_host, vault_entry, read_only, created_at, updated_at) " \
      "VALUES (1, 'old@example.com', 'imap.example.com', 'Old', 1, '#{@now}', '#{@now}')")

    run_migrations { it == VERSION }

    # Saved by code from before, which names no primary.
    account(2, "desk2@example.com")
    assert_equal [ [ "desk1@example.com", 0, 0 ], [ "old@example.com", 1, 0 ], [ "desk2@example.com", 0, 0 ] ],
      @connection.select_rows(%(SELECT address, read_only, "primary" FROM agent_mail_accounts ORDER BY id))
  end

  private
    def execute(sql) = @connection.execute(sql)

    def account(agent_id, address)
      execute("INSERT INTO agent_mail_accounts (agent_id, address, smtp_host, imap_host, vault_entry, created_at, updated_at) " \
        "VALUES (#{agent_id}, '#{address}', 'smtp.example.com', 'imap.example.com', 'Mailbox', '#{@now}', '#{@now}')")
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
