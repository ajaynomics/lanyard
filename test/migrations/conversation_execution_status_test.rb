require "test_helper"
require "tmpdir"

# 20261115010000 records whether a thread's own run is going apart from
# whether a card waits on the person (Conversation::Activity). A running, idle
# or stopped thread keeps what it was; a waiting one can't say whether its run
# is still going, so it starts unknown until the sidecar is next asked. The
# status every reader uses is left as it was. Run on a database of its own
# built by the migrations before it.
class ConversationExecutionStatusTest < ActiveSupport::TestCase
  VERSION = 20261115010000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("execution-status")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "each existing thread's run is taken from its status, a waiting one's is unknown, and the status stays" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    %w[ idle running waiting error new ].each.with_index(1) do |status, id|
      @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) " \
        "VALUES (#{id}, 1, 'Maya #{id}', 'Help.', 'm', 'maya#{id}', '#{now}', '#{now}')")
      next if status == "new"
      @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, title, status, listed_at, created_at, updated_at) " \
        "VALUES (#{id}, 1, #{id}, 'r#{id}', 'Trip', '#{status}', '#{now}', '#{now}', '#{now}')")
    end

    run_migrations { it == VERSION }

    assert_equal [ [ 1, "idle", "idle" ], [ 2, "running", "running" ], [ 3, "waiting", "unknown" ], [ 4, "error", "error" ] ],
      @connection.select_rows("SELECT id, status, execution_status FROM conversations ORDER BY id")

    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, title, listed_at, created_at, updated_at) " \
      "VALUES (5, 1, 5, 'r5', 'New', '#{now}', '#{now}', '#{now}')")
    assert_equal [ "idle", "idle" ], @connection.select_rows("SELECT status, execution_status FROM conversations WHERE id = 5").sole,
      "a thread made by code from before the change starts as idle as its status says"
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
