# On the calls queue (config/queue.yml): an agent waits on this ring.
class InvocationWakeJob < ApplicationJob
  queue_as :calls
  # The sidecar also re-sends a waiting call every minute, so a lost ring
  # costs at most that; retries here only make it sooner.
  retry_on DurableAssistants::PiDurable::Client::Error, wait: :polynomially_longer, attempts: 5

  # A call handed back has no wait in the sidecar to ring: Rails moves it
  # on itself, running it once the person allows it (Invocation#hand_back).
  def perform(invocation)
    invocation.handed_back_at ? invocation.advance : invocation.conversation.wake(invocation)
  end
end
