# Makes a claimed outside call (Invocation#call_outside) away from the
# sidecar's request, which waits 10 seconds; a sleeping Sprite or a slow server
# can take minutes. Then rings the doorbell, as a person's decision does. A
# job lost on the way leaves the call running, and the sidecar's next ask after
# Invocation::RUN_LIMIT claims it again.
class InvocationCallJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(invocation)
    invocation.call_outside
    InvocationWakeJob.perform_later(invocation) unless invocation.running?
  end
end
