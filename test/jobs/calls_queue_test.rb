require "test_helper"

# A tool call waited minutes behind sweeps and broadcasts on the job role's
# three shared threads, past Invocation::RUN_LIMIT (#238). What an agent or
# a person waits on goes on a queue with a worker of its own.
class CallsQueueTest < ActiveSupport::TestCase
  WAITED_ON = [ InvocationCallJob, InvocationWakeJob, InvocationPreviewJob ]

  test "what an agent or a person waits on goes on the calls queue, and the sweeps do not" do
    WAITED_ON.each { assert_equal "calls", it.new.queue_name, it.name }
    [ ConcourseSweepJob, ConversationRecoveryJob, ConcourseListenJob, Turbo::Streams::BroadcastStreamJob ].each do
      assert_equal "default", it.new.queue_name, it.name
    end
  end

  test "production has a worker for the calls queue alone, beside the one for every queue, each within its database pool" do
    workers = production_queue["workers"]
    assert_equal [ "calls", "mail", "*" ], workers.map { it["queues"] }
    # Each worker process's pool is RAILS_MAX_THREADS (config/database.yml);
    # Solid Queue needs its threads plus 2 for polling and the heartbeat.
    workers.each { assert_operator it["threads"] + 2, :<=, 5, it["queues"] }
  end

  private
    def production_queue
      YAML.load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true).fetch("production")
    end
end
