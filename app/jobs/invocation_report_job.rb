# Tells the agent how a call it handed back ended (Invocation#report). The
# message keeps its request id, so a retry is the same message, sent once.
class InvocationReportJob < ApplicationJob
  retry_on DurableAssistants::PiDurable::Client::Error, Conversation::Submission::Refused, wait: :polynomially_longer, attempts: 10
  discard_on ActiveJob::DeserializationError

  def perform(invocation) = invocation.report
end
