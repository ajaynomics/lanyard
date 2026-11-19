# Tells the agent how a sign-in link it asked for ended (SignInLink#report):
# filled or not, never with what. The message keeps its request id, so a
# retry is the same message, sent once.
class SignInLinkReportJob < ApplicationJob
  retry_on DurableAssistants::PiDurable::Client::Error, Conversation::Submission::Refused, wait: :polynomially_longer, attempts: 10
  discard_on ActiveJob::DeserializationError

  def perform(sign_in_link)
    sign_in_link.conversation.receive(from: "the sign-in link you asked for", via: "Approval",
      request_id: "sign_in_link:#{sign_in_link.id}", when_busy: "steer", source: { invocation_id: sign_in_link.invocation_id }) do
      [ sign_in_link.report, "It answers a sign-in link you made earlier with ask_outside_for_sign_in. Tell the person what matters." ]
    end
  end
end
