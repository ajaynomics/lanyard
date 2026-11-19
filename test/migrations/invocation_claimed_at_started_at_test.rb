require "test_helper"
require "tmpdir"

# 20261118220000 records when an outside call was claimed and when its job
# began it (Invocation#overdue, #238). Additive and nullable: a call already
# running keeps neither, so it keeps the rule it had (lost five minutes on),
# as does one claimed by code from before during a rolling deploy. Run on a
# database of its own built by the migrations before it.
class InvocationClaimedAtStartedAtTest < ActiveSupport::TestCase
  VERSION = 20261118220000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("claimed-at")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a call already running keeps neither time, and one inserted by code from before has neither" do
    now = Time.current.utc.iso8601
    # Only the invocations table matters here, not the rows it would belong to.
    @connection.execute("PRAGMA foreign_keys = OFF")
    @connection.execute("INSERT INTO invocations (id, conversation_id, task_id, call_id, tool_name, digest, state, created_at, updated_at) " \
      "VALUES (1, 1, '7', 'toolu_1', 'concourse_reply', 'd', 'running', '#{now}', '#{now}')")

    run_migrations { it >= VERSION }

    assert_equal [ [ 1, "running", now, nil, nil ] ], @connection.select_rows("SELECT id, state, updated_at, claimed_at, started_at FROM invocations")
    @connection.execute("INSERT INTO invocations (id, conversation_id, task_id, call_id, tool_name, digest, state, created_at, updated_at) " \
      "VALUES (2, 1, '7', 'toolu_2', 'concourse_reply', 'e', 'running', '#{now}', '#{now}')")
    assert_equal [ nil, nil ], @connection.select_rows("SELECT claimed_at, started_at FROM invocations WHERE id = 2").sole
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
