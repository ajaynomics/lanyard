require "test_helper"

# Mail and texts reached an agent in 10-66 s (#262): a read waited 2-13 s
# behind the minute's sweeps and the page's broadcasts on the job role's
# shared threads. Reading a box, and routing what it held, go on a queue with
# a worker of its own, in the same job role (bin/jobs).
class MailQueueTest < ActiveSupport::TestCase
  MAIL = [ EmailFetchJob, CatchAllFetchJob, MailAccountFetchJob, WorkspaceMailFetchJob ]

  test "every read of a box goes on the mail queue, and so does routing what it held" do
    MAIL.each { assert_equal MailIdler::QUEUE, it.new.queue_name, it.name }
    assert_equal MailIdler::QUEUE, ActionMailbox::RoutingJob.new.queue_name,
      "routing what the catch-all held waits behind the sweeps again"
  end

  test "production has a worker for the mail queue alone, with a database connection left for the idler" do
    worker = production_queue["workers"].find { it["queues"] == MailIdler::QUEUE }
    assert worker, "no worker reads the mail queue, so a fetch still waits behind the sweeps"
    assert_equal 1, worker["processes"], "one process, so an install has one idler holding one connection per box"
    # Each worker process's pool is RAILS_MAX_THREADS (config/database.yml);
    # Solid Queue needs its threads plus 2 for polling and the heartbeat, and
    # a watcher takes one more for the moment it enqueues a read.
    assert_operator worker["threads"] + 3, :<=, 5, "no connection is left for a watcher to enqueue a read with"
  end

  private
    def production_queue
      YAML.load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true).fetch("production")
    end
end
