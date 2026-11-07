# Mail an agent sends, from its own address (Tool::SendEmail). A reply carries
# the message it answers in In-Reply-To and References, so it lands in the
# same thread of mail.
class AgentMailer < ApplicationMailer
  layout false

  def message_from(agent, to:, subject:, body:, in_reply_to: nil)
    @body = body
    headers["In-Reply-To"] = headers["References"] = "<#{in_reply_to}>" if in_reply_to
    mail from: email_address_with_name(agent.email_address, agent.name), to: to, subject: subject do |format|
      format.text { render plain: body }
    end
  end
end
