# Tells the agent how mail held for its sending hours ended (HeldEmail). The
# message keeps its request id, so a retry is the same message, sent once.
class HeldEmailReportJob < ApplicationJob
  retry_on DurableAssistants::PiDurable::Client::Error, Conversation::Submission::Refused, wait: :polynomially_longer, attempts: 10
  discard_on ActiveJob::DeserializationError

  def perform(held_email, text)
    held_email.conversation.receive(from: "the email you sent outside your sending hours", via: "Approval",
      request_id: "held_email:#{held_email.id}", when_busy: "steer", source: { invocation_id: held_email.invocation_id }) do
      [ text, "It answers an email you sent earlier, which waited for your sending hours. Tell the person what matters." ]
    end
  end
end
