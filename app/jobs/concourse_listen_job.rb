# Holds one bot's Concourse doorbell open in the job role until the server
# closes it (at most 15 minutes), then enqueues itself again. Each ping
# enqueues a sweep (PARITY.md §28). One per bot: a second is discarded, so the
# minute's sweep may enqueue one whenever it likes and only a missing listener
# starts.
class ConcourseListenJob < ApplicationJob
  RECONNECT = 5.seconds # after the semaphore is released, so the next is not discarded
  AFTER_FAILURE = 30.seconds # as the Pi connector waits

  limits_concurrency key: ->(concourse_agent) { concourse_agent }, duration: 20.minutes, on_conflict: :discard
  discard_on ActiveJob::DeserializationError # taken off Concourse meanwhile

  def perform(concourse_agent)
    wait = AFTER_FAILURE
    concourse_agent.listen
    wait = RECONNECT
  rescue DurableAssistants::Concourse::Client::Error => problem
    Rails.logger.warn("Concourse doorbell for #{concourse_agent}: #{problem.message}")
  ensure
    self.class.set(wait: wait).perform_later(concourse_agent) if concourse_agent.class.exists?(concourse_agent.id) # tenancy-ok: this record, still there
  end
end
