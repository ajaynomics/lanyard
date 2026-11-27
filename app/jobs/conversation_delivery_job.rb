# A channel's prepared turn can wait out a computer rebuild without keeping
# its receiver or a worker open. Retries carry the record, not the payload.
class ConversationDeliveryJob < ApplicationJob
  limits_concurrency key: ->(submission) { submission }
  retry_on Conversation::Submission::ComputerHeld, wait: :polynomially_longer, attempts: 10 do |job|
    job.arguments.first.computer_hold_expired
  end
  discard_on ActiveJob::DeserializationError

  def perform(submission) = submission.deliver(wait_for_computer: true)
end
