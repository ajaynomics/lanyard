require "test_helper"
require "tmpdir"

# 20261115090000 adds who said a message: its request id, its author and its
# sender. An existing message keeps its row and words, with none of them, so it
# is read from its words as before (Message#incoming). Run on a database of its
# own built by the migrations before it.
class MessageSpeakersMigrationTest < ActiveSupport::TestCase
  VERSION = 20261115090000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("message-speakers")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an existing message keeps its row and words, with no speaker" do
    insert "users", id: 1, oidc_sub: "s", name: "Maya", email: "maya@example.com"
    insert "agents", id: 1, user_id: 1, name: "Robin", instructions: "Help.", model: "m", email_name: "robin"
    insert "conversations", id: 1, user_id: 1, agent_id: 1, request_id: "r"
    insert "messages", id: 1, conversation_id: 1, entry_key: "1", entry_id: 1, role: "user", content: "Yes"
    run_migrations { it == VERSION }
    assert_equal [ [ 1, "1", "user", "Yes", nil, nil, nil ] ],
      @connection.select_rows("SELECT id, entry_key, role, content, request_id, author_id, sender FROM messages")
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

    def insert(table, **values)
      now = Time.current.utc.iso8601
      columns = @connection.columns(table).map(&:name)
      values = { created_at: now, updated_at: now, listed_at: now }.select { |column, _| columns.include?(column.to_s) }.merge(values)
      @connection.execute("INSERT INTO #{table} (#{values.keys.join(', ')}) VALUES (#{values.values.map { @connection.quote(it) }.join(', ')})")
    end
end
