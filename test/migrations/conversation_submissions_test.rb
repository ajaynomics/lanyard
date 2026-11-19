require "test_helper"
require "tmpdir"

class ConversationSubmissionsTest < ActiveSupport::TestCase
  VERSION = 20261114190000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("conversation-submissions")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing rows and legacy writers survive while new envelopes have a scoped unique ID and cascading owner" do
    now = @connection.quote(Time.current.utc.iso8601)
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', #{now}, #{now})")
    @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) VALUES (1, 1, 'Helper', 'Help', 'local/stand-in', 'helper', #{now}, #{now})")
    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, status, listed_at, created_at, updated_at) VALUES (1, 1, 1, 'legacy', 'waiting', #{now}, #{now}, #{now})")
    @connection.execute("INSERT INTO shares (id, user_id, text, created_at, updated_at) VALUES (1, 1, 'My unsent draft', #{now}, #{now})")
    before = %w[ users agents conversations shares ].to_h { |name| [ name, @connection.select_all("SELECT * FROM #{name}").to_a ] }
    run_migrations { it == VERSION }

    before.each do |table, rows|
      after = @connection.select_all("SELECT * FROM #{table}").to_a
      after.each { it.delete("submission_request_id") } if table == "shares"
      assert_equal rows, after, table
    end
    assert_nil @connection.select_value("SELECT submission_request_id FROM shares WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM conversation_submissions")
    @connection.execute("INSERT INTO shares (user_id, text, created_at, updated_at) VALUES (1, 'An old writer', #{now}, #{now})")
    assert_equal 2, @connection.select_value("SELECT COUNT(*) FROM shares")

    insert = "INSERT INTO conversation_submissions (conversation_id, request_id, input_digest, payload_digest, definition_digest, created_at, updated_at) VALUES (1, 'send-1', 'input', 'body', 'definition', #{now}, #{now})"
    @connection.execute(insert)
    assert_equal({}, JSON.parse(@connection.select_value("SELECT context FROM conversation_submissions")))
    assert_nil @connection.select_value("SELECT receipt FROM conversation_submissions")
    assert_raises(ActiveRecord::RecordNotUnique) { @connection.execute(insert) }
    @connection.execute("DELETE FROM conversations WHERE id = 1")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM conversation_submissions")
  end

  private
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
