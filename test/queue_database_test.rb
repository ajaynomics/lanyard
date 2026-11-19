require "test_helper"

# On a busy host a disk stall can keep the queue database's write lock for
# longer than Rails' usual 5 s wait, and Solid Queue's dispatcher or worker
# then dies with "database is locked". The queue database waits longer; the
# primary does not, because a waiting request holds one of a Falcon process's
# few connections.
class QueueDatabaseTest < ActiveSupport::TestCase
  # Fixture transactions would open one on the queue connection too, and hold
  # the very lock this test is about.
  self.use_transactional_tests = false

  setup do
    @path = Rails.root.join("tmp/queue-wait-test-#{Process.pid}.sqlite3").to_s
    @queue = production_config("queue", database: @path)
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(@queue) { load Rails.root.join("db/queue_schema.rb") }
    end
    SolidQueue::Record.establish_connection(@queue)
  end

  teardown do
    SolidQueue::Record.remove_connection
    FileUtils.rm_f(Dir["#{@path}*"])
  end

  test "the dispatcher waits out a write lock held longer than 5 s" do
    held = Thread::Queue.new
    holder = Thread.new do
      SQLite3::Database.new(@path) do |db|
        db.execute("BEGIN IMMEDIATE")
        held << true
        sleep 7
        db.execute("COMMIT")
      end
    end
    held.pop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_nothing_raised { SolidQueue::ScheduledExecution.dispatch_next_batch(500) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>, 6, "the lock was not held"
  ensure
    holder&.join
  end

  test "the primary keeps the short wait" do
    assert_equal 5000, production_config("primary").configuration_hash[:timeout]
  end

  private
    def production_config(name, **overrides)
      config = ActiveRecord::Base.configurations.configs_for(env_name: "production", name: name)
      ActiveRecord::DatabaseConfigurations::HashConfig.new("test", name, config.configuration_hash.merge(overrides))
    end
end
