require "test_helper"
require "tmpdir"

# 20261116100000 adds an agent's own mail account (#77) as a table of its own.
# Additive: every existing agent has none and so sends as before, and an
# agent made by code from before, during a rolling deploy, has none either.
# Run on a database of its own built by the migrations before it, then its own.
class AgentMailAccountsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116100000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("mail-accounts")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing agents, and one made by code from before, have no account; one is one per agent, gone with it" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    insert_agent(1, "iris", now)

    run_migrations { it == VERSION }

    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM agent_mail_accounts")
    insert_agent(2, "juno", now)
    assert_equal [ 1, 2 ], @connection.select_values("SELECT id FROM agents ORDER BY id")

    @connection.execute("INSERT INTO agent_mail_accounts (agent_id, address, smtp_host, vault_entry, created_at, updated_at) " \
      "VALUES (1, 'desk@example.com', 'smtp.example.com', 'Mailbox', '#{now}', '#{now}')")
    assert_equal [ [ 587, 993, nil, nil ] ], @connection.select_rows("SELECT smtp_port, imap_port, imap_host, forced_bcc FROM agent_mail_accounts")
    assert_raises(ActiveRecord::RecordNotUnique) do
      @connection.execute("INSERT INTO agent_mail_accounts (agent_id, address, smtp_host, vault_entry, created_at, updated_at) " \
        "VALUES (1, 'other@example.com', 'smtp.example.com', 'Mailbox', '#{now}', '#{now}')")
    end
  end

  private
    def insert_agent(id, name, now)
      @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (#{id}, 1, 1, '#{name.capitalize}', 'Help.', 'm', '#{name}', '#{now}', '#{now}')")
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
