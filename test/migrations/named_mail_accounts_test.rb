require "test_helper"
require "tmpdir"

# 20261125080000 lets an agent have accounts it sends from only when a message
# names them (#630). Every existing account, and one saved by code from before
# during a rolling deploy, stays its default; the database still keeps that to
# one per agent, with any number used only when named beside it.
class NamedMailAccountsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261125080000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("named-mail-accounts")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing accounts stay the default, still one per agent, and any number used only when named go beside it" do
    @now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{@now}', '#{@now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{@now}', '#{@now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{@now}', '#{@now}')")
    account("desk@example.com")

    run_migrations { it == VERSION }

    assert_equal [ [ "desk@example.com", 0 ] ], @connection.select_rows("SELECT address, only_when_named FROM agent_mail_accounts")
    assert_raises(ActiveRecord::RecordNotUnique) { account("other@example.com") }
    account("owner@example.com", named: 1)
    account("team@example.com", named: 1)
    assert_equal 3, @connection.select_value("SELECT COUNT(*) FROM agent_mail_accounts")
  end

  private
    def account(address, named: nil)
      columns, values = named ? [ ", only_when_named", ", #{named}" ] : [ "", "" ]
      @connection.execute("INSERT INTO agent_mail_accounts (agent_id, address, smtp_host, vault_entry, created_at, updated_at#{columns}) " \
        "VALUES (1, '#{address}', 'smtp.example.com', 'Mailbox', '#{@now}', '#{@now}'#{values})")
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
