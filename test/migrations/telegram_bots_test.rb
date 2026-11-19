require "test_helper"
require "tmpdir"

# 20261116210000 adds agents' Telegram bots (TelegramBot): a new, empty table,
# so every existing agent is as it was. Code from before deletes agents
# without knowing it, so its key cascades; it goes back down cleanly. Run on a
# database of its own built by the migrations before it, then it alone.
class TelegramBotsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261116210000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("telegram-bots")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Rob', 'rob@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing agents keep everything and have no bot; a bot goes with its agent as code from before deletes it; it goes back down" do
    before = @connection.select_all("SELECT * FROM agents").to_a
    run_migrations(:up) { it == VERSION }
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM telegram_bots")
    assert_equal before, @connection.select_all("SELECT * FROM agents").to_a

    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO telegram_bots (agent_id, vault_entry, webhook_secret, created_at, updated_at) VALUES (1, 'Bot', 's', '#{now}', '#{now}')")
    assert_raises(ActiveRecord::RecordNotUnique) do
      @connection.execute("INSERT INTO telegram_bots (agent_id, vault_entry, webhook_secret, created_at, updated_at) VALUES (1, 'Bot', 't', '#{now}', '#{now}')")
    end
    assert_equal({}, JSON.parse(@connection.select_value("SELECT chats FROM telegram_bots")))
    @connection.execute("DELETE FROM agents WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM telegram_bots")

    run_migrations(:down) { it == VERSION }
    assert_not @connection.table_exists?(:telegram_bots)
  end

  private
    def run_migrations(direction)
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, direction) }
      end
    end
end
