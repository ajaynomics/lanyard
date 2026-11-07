# Mail to an agent's address goes to its thread, marked as untrusted mail
# from its sender, with what it needs to reply in the same thread of mail
# (Tool::SendEmail). Mail that names no agent is left alone: the box is the
# whole domain's.
class AgentsMailbox < ApplicationMailbox
  def process
    agents.each do |agent|
      agent.conversation.receive(text, from: mail[:from].to_s, via: "Email", request_id: "email:#{agent.id}:#{inbound_email.message_id}",
        answer: "To reply, use send_email to #{mail.reply_to&.first || mail.from&.first} with in_reply_to #{inbound_email.message_id}; ending your turn does not reply.")
    rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch, Conversation::ImagesRefused => problem
      # One agent that cannot take it now must not hold up the rest.
      Rails.logger.warn("Email #{inbound_email.id} not delivered to agent #{agent.id}: #{problem.class.name}")
    end
  end

  private
    # The envelope recipient of a catch-all box is in Delivered-To or
    # X-Original-To when the message itself names someone else (Bcc).
    def agents
      names = (Array(mail.to) + Array(mail.cc) + %w[ Delivered-To X-Original-To ].flat_map { Array(mail.header[it]).map(&:value) })
        .filter_map { it.to_s.downcase[/\A[^@\s<]+(?=@#{Regexp.escape(DurableAssistants::Email.domain.to_s)}\z)/] }
      sender = mail.from&.first.to_s.downcase
      Agent.where(email_name: names.uniq).reject { it.email_address == sender } # tenancy-ok: an address names its agent, whoever owns it
    end

    def text
      body = if mail.multipart? then mail.text_part&.decoded || html_text(mail.html_part&.decoded)
      elsif mail.mime_type == "text/html" then html_text(mail.decoded)
      else mail.decoded
      end
      "Subject: #{mail.subject}\nDate: #{mail.date}\nTo: #{mail[:to]}\n\n#{body.to_s.strip}"
    end

    def html_text(html) = ActionView::Base.full_sanitizer.sanitize(html.to_s).gsub(/\n{3,}/, "\n\n")
end
