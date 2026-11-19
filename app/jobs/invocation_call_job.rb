# Makes a claimed outside call (Invocation#call_outside) away from the
# sidecar's request, which waits 10 seconds; a sleeping Sprite or a slow server
# can take minutes. Then rings the doorbell, as a person's decision does. A
# job lost on the way (a worker killed mid-call) leaves the call running, and
# the sidecar's next ask after Invocation::RUN_LIMIT fails it, never makes it
# again: it may have happened. Only a tool safe to repeat runs again. One
# that never began waits for it, on the calls queue (config/queue.yml), so
# sweeps and broadcasts do not hold it up.
class InvocationCallJob < ApplicationJob
  queue_as :calls
  discard_on ActiveJob::DeserializationError

  # Whether Solid Queue still holds a job for this call that may yet run: not
  # finished, and not failed. Another adapter (tests, development) cannot be
  # asked, so its job is taken to be there, and the call waits it out. The
  # quoted id ends the match, so call 12's job is not call 123's.
  def self.queued?(invocation)
    return true unless queue_adapter.is_a?(ActiveJob::QueueAdapters::SolidQueueAdapter)
    SolidQueue::Job.where(class_name: name, finished_at: nil).where.missing(:failed_execution)
      .where("arguments LIKE ?", "%#{invocation.to_global_id.to_s.to_json}%").exists?
  end

  def perform(invocation)
    invocation.call_outside
    InvocationWakeJob.perform_later(invocation) unless invocation.running?
  end
end
