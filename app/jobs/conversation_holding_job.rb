# Brings what a paused agent's thread holds up to date (Conversation::Holding).
# Paused or resumed, it first takes back what waits in the sidecar from before
# the resume; resumed, it then sends what was held, in order, and only then
# lets the agent stop holding. A message the sidecar refuses for good is set
# aside; any other error is tried again a minute on, for good: the pause or
# the resume stays meanwhile, and running it again is safe. One at a time per
# thread, and the one job of a resume: what comes meanwhile adds none. Each
# message goes under its own id, so a send whose answer was lost is never read twice.
class ConversationHoldingJob < ApplicationJob
  limits_concurrency key: ->(conversation) { conversation }
  retry_on StandardError, wait: 1.minute, jitter: 0, attempts: :unlimited
  discard_on ActiveJob::DeserializationError

  def perform(conversation)
    conversation.hold_queued
    conversation.deliver_held
  end
end
