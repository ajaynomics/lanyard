class InvocationWakeJob < ApplicationJob
  # The sidecar also re-sends a waiting call every minute, so a lost ring
  # costs at most that; retries here only make it sooner.
  retry_on DurableAssistants::PiDurable::Client::Error, wait: :polynomially_longer, attempts: 5

  def perform(invocation)
    invocation.conversation.wake(invocation)
  end
end
