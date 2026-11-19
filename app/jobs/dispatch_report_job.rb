# Tells the agent what became of a message whose answer never came: what
# the provider's list showed (Dispatch#check), or what a person who checked
# said (Dispatch#close). Each keeps its request id, so a retry is the same
# message, sent once.
class DispatchReportJob < ApplicationJob
  retry_on DurableAssistants::PiDurable::Client::Error, Conversation::Submission::Refused, wait: :polynomially_longer, attempts: 10
  discard_on ActiveJob::DeserializationError

  def perform(dispatch, text, request_id)
    dispatch.conversation.receive(from: "a message you sent earlier", via: "Approval",
      request_id: request_id, when_busy: "steer", source: { invocation_id: dispatch.invocation_id }) do
      [ text, "It answers a send of yours whose answer never came. Tell the person what matters." ]
    end
  end
end
