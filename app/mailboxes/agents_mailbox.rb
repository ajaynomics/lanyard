# Mail to an agent's address goes to its thread, marked as untrusted mail
# from its sender, with what it needs to reply in the same thread of mail
# (Tool::SendEmail). A text voip.ms forwards to it (docs/phone.md) arrives as
# a text from its number, answered with send_text. Mail that names no agent
# is left alone: the box is the whole domain's. Mail to an agent another has
# replaced goes to that one instead (Agent#mail_to_agent).
class AgentsMailbox < ApplicationMailbox
  # voip.ms's SMS-to-email: From sms@voip.ms, and the sender in the subject,
  # "Message received from number 9055550188 to number 4165550123 [#…]". Like
  # any mail it may be forged; a text back still asks the person first.
  TEXT_SENDER = "sms@voip.ms"
  TEXT_SUBJECT = /\AMessage received from number (\d{10}) to number \d{10}\b/

  def process
    agents.each do |agent, addressed|
      agent.conversation.receive(text(addressed), **(texter ? as_text(agent) : as_email), sent_at: mail.date&.to_time,
        request_id: "email:#{agent.id}:#{inbound_email.message_id}")
    rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch, Conversation::ImagesRefused => problem
      # One agent that cannot take it now must not hold up the rest.
      Rails.logger.warn("Email #{inbound_email.id} not delivered to agent #{agent.id}: #{problem.class.name}")
    end
  end

  private
    def as_email
      { from: mail[:from].to_s, via: "Email",
        answer: "To reply, use send_email to #{mail.reply_to&.first || mail.from&.first} with in_reply_to #{inbound_email.message_id}; ending your turn does not reply." }
    end

    def as_text(agent)
      { from: texter, via: "Text",
        answer: agent.texts? ? "To reply, use send_text to #{texter}; ending your turn does not reply." : "You have no phone number here to text back from." }
    end

    # The number that texted, when this is voip.ms forwarding a text.
    def texter
      @texter ||= (mail.from&.first.to_s.downcase == TEXT_SENDER && mail.subject.to_s[TEXT_SUBJECT, 1]) || nil
    end

    # The envelope recipient of a catch-all box is in Delivered-To or
    # X-Original-To when the message itself names someone else (Bcc). An
    # agent another has replaced passes its mail on, one step, and is not
    # woken (Agent#mail_to_agent). Each agent that takes the mail, with the
    # agents it came through, if any.
    def agents
      names = (Array(mail.to) + Array(mail.cc) + %w[ Delivered-To X-Original-To ].flat_map { Array(mail.header[it]).map(&:value) })
        .filter_map { it.to_s.downcase[/\A[^@\s<]+(?=@#{Regexp.escape(DurableAssistants::Email.domain.to_s)}\z)/] }
      sender = mail.from&.first.to_s.downcase
      named = Agent.where(email_name: names.uniq).includes(:mail_to_agent).to_a # tenancy-ok: an address names its agent, whoever owns it
      named.reject { [ it, it.mail_to_agent ].compact.any? { it.email_address == sender } }
        .group_by { it.mail_to_agent || it }.transform_values { |agents| agents.select(&:mail_to_agent) }
    end

    def text(addressed = [])
      body = if mail.multipart? then mail.text_part&.decoded || html_text(mail.html_part&.decoded)
      elsif mail.mime_type == "text/html" then html_text(mail.decoded)
      else mail.decoded
      end
      sent_to = addressed.map { "Sent to #{it.email_address}, the address of #{it.name}, which now comes to you.\n" }.join
      "Subject: #{mail.subject}\nDate: #{mail.date}\nTo: #{mail[:to]}\n#{sent_to}\n#{body.to_s.strip}"
    end

    def html_text(html) = ActionView::Base.full_sanitizer.sanitize(html.to_s).gsub(/\n{3,}/, "\n\n")
end
