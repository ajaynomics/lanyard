require "test_helper"
require "tmpdir"

# 20261118204100 keeps what Telegram bots hear (TelegramMessage, #189): a new,
# empty table, so every existing bot is as it was. Code from before deletes
# bots and agents without knowing it, so its key cascades; it goes back down
# cleanly. Run on a database of its own built by the migrations before it,
# then it alone.
class TelegramMessagesMigrationTest < ActiveSupport::TestCase
  VERSION = 20261118204100
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("telegram-messages")
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

  test "existing bots keep everything and have heard nothing; a post is kept once and goes with its bot; it goes back down" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO telegram_bots (id, agent_id, vault_entry, username, webhook_secret, chats, created_at, updated_at) " \
      "VALUES (1, 1, 'Bot', 'desk_example_bot', 's', '{\"-100\":\"Weekend plans\"}', '#{now}', '#{now}')")
    before = @connection.select_all("SELECT * FROM telegram_bots").to_a
    run_migrations(:up) { it == VERSION }
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM telegram_messages")
    assert_equal before, @connection.select_all("SELECT * FROM telegram_bots").to_a

    insert = "INSERT INTO telegram_messages (telegram_bot_id, chat_id, message_id, sender, text, sent_at, created_at) " \
      "VALUES (1, -1001234567890, 7, 'Maya', 'Hi', '#{now}', '#{now}')"
    @connection.execute(insert)
    assert_raises(ActiveRecord::RecordNotUnique) { @connection.execute(insert) }
    @connection.execute("DELETE FROM agents WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM telegram_messages")

    run_migrations(:down) { it == VERSION }
    assert_not @connection.table_exists?(:telegram_messages)
    assert @connection.table_exists?(:telegram_bots)
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
