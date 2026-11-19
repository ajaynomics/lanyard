require "test_helper"
require "tmpdir"

# 20261115050000 lets a call waiting on an approval hand its card back to
# Rails. Additive: every existing call, and one made by code from before
# during a rolling deploy, stays the sidecar's to wait on. Run on a database
# of its own built by the migrations before it.
class InvocationHandedBackAtTest < ActiveSupport::TestCase
  VERSION = 20261115050000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("handed-back-at")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing calls, and one made by code from before, are not handed back" do
    now = Time.current.utc.iso8601
    # Only the invocations table matters here, not the rows it would belong to.
    @connection.execute("PRAGMA foreign_keys = OFF")
    @connection.execute("INSERT INTO invocations (id, conversation_id, task_id, call_id, tool_name, digest, state, created_at, updated_at) " \
      "VALUES (1, 1, '7', 'toolu_1', 'forget_note', 'd', 'awaiting_person', '#{now}', '#{now}')")

    run_migrations { it >= VERSION }

    assert_equal [ [ 1, "awaiting_person", nil ] ], @connection.select_rows("SELECT id, state, handed_back_at FROM invocations")
    @connection.execute("INSERT INTO invocations (id, conversation_id, task_id, call_id, tool_name, digest, state, created_at, updated_at) " \
      "VALUES (2, 1, '7', 'toolu_2', 'forget_note', 'e', 'pending', '#{now}', '#{now}')")
    assert_nil @connection.select_value("SELECT handed_back_at FROM invocations WHERE id = 2")
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
