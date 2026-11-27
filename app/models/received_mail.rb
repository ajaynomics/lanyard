# One message as an agent reads it, whichever box it came from: the install's
# catch-all (AgentsMailbox) or the agent's own (Agent::MailAccount::Inbox). It
# reaches the thread marked as untrusted mail from its sender, with what the
# agent needs to reply in the same thread of mail (Tool::SendEmail), or, when
# voip.ms forwards a text (docs/phone.md), as a text from its number, answered
# with send_text. Its request id is the agent's and the message's alone, so a
# message in both boxes reaches the thread once. From a mailbox the agent only
# reads (Agent::MailAccount, read_only), it says which mailbox and folder it
# was found in, and that a reply goes from the agent's own address. Its
# files are saved on the agent's computer and listed (ReceivedMail::Files).
class ReceivedMail
  include Automated

  # voip.ms's SMS-to-email: From sms@voip.ms, and the sender in the subject,
  # "Message received from number 9055550188 to number 4165550123 [#…]". Like
  # any mail it may be forged; a text back still asks the person first.
  TEXT_SENDER = "sms@voip.ms"
  TEXT_SUBJECT = /\AMessage received from number (\d{10}) to number \d{10}\b/

  attr_reader :mail, :message_id, :found_in

  # found_in: [address, folder] of a mailbox the agent only reads.
  def initialize(mail, message_id:, found_in: nil, source: nil)
    @mail, @message_id, @found_in, @source = mail, message_id, found_in, source
  end

  # `addressed`: the agents it was sent to that pass their mail to this one (Agent#mail_to_agent).
  # From a contact the workspace routed to another of its agents, it goes to
  # that one instead (Workspace::ContactRoute), saying so; several of the
  # workspace's agents it was sent to share the one request id, so it arrives
  # once. Mail found in a mailbox the agent only reads stays with it.
  def deliver_to(agent, addressed = [])
    routed_from, agent = agent, routed(agent)
    request_id = "email:#{agent.id}:#{message_id}"
    # A retry may follow a crash after preparing or handing off the message.
    # Reuse the same envelope, without applying its calendar answer twice.
    if gmail? && (previous = agent.conversation.submissions.find_by(request_id: request_id))
      return previous.deliver_incoming unless previous.acknowledged_at
      return
    end
    agent.conversation.receive(text(addressed, files.listing(agent, request_id), routed_from: (routed_from unless routed_from == agent),
        blind: blind_copy_to([ routed_from, *addressed ]), answered: answered(agent)),
      **(texter ? as_text(agent) : as_email), **urgency(agent), sent_at: mail.date&.to_time, request_id: request_id)
  rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch, Conversation::ImagesRefused, Conversation::Submission::Refused => problem
    raise if gmail?
    # One agent that cannot take it now must not hold up the rest.
    Rails.logger.warn("Email not delivered to agent #{agent.id}: #{problem.class.name}")
  end

  private
    def gmail? = @source == :gmail

    def routed(agent)
      return agent if found_in || gmail?
      agent.workspace.answerer_for(sender) || agent
    end

    # A guest answering one of the agent's own invitations (CalendarReply,
    # #261): the answer goes on the event, and what happened is said above the
    # message. A message that only looks like one, or that comes from anyone
    # but the guest, changes nothing and is shown all the same.
    def answered(agent)
      CalendarReply.in(mail)&.apply(agent, source: @source)
    rescue StandardError => problem
      Rails.logger.warn("Calendar answer not applied for agent #{agent.id}: #{problem.class.name}")
      nil
    end

    # Who sent it: the number that texted, or the address it came from.
    def sender = texter || mail.from&.first

    # An automated notice, or mail found in a mailbox it only reads, waits for
    # the agent's turn to end, whatever it says; a person's goes by the one
    # rule for every channel (Conversation#receive), its subject or its first
    # words counting as its opening.
    def urgency(agent)
      return { when_busy: "followUp" } if found_in || automated?
      { opening: [ mail.subject, body_text ], marked_urgent: urgent_mark?, from_person: from_agents_person?(agent) }
    end

    # Importance: high, Priority: urgent, X-Priority: 1 or 2.
    def urgent_mark?
      mail.header["Importance"].to_s.strip.casecmp?("high") || mail.header["Priority"].to_s.strip.casecmp?("urgent") ||
        mail.header["X-Priority"].to_s.strip.match?(/\A[12]\b/)
    end

    # Mail may be forged: this changes only when it is read, never what it may do.
    def from_agents_person?(agent)
      !texter && agent.user.email.present? && mail.from&.first.to_s.casecmp?(agent.user.email)
    end

    def as_email
      { from: mail[:from].to_s, via: "Email",
        answer: found_in ? answer_found : "To reply, use send_email to #{mail.reply_to&.first || mail.from&.first} with in_reply_to #{message_id}; ending your turn does not reply." }
    end

    # Its own mail, in its Sent or Drafts, is followed up with whom it was to.
    def answer_found
      address, = found_in
      own = mail.from&.first.to_s.downcase == address
      to = own ? Array(mail.to).first : (mail.reply_to&.first || mail.from&.first)
      "#{address} is a mailbox you read and never send from. To #{own ? "follow it up" : "reply"}, use send_email to #{to} with in_reply_to #{message_id}: " \
        "it goes from your own address. Ending your turn does not reply."
    end

    def as_text(agent)
      { from: texter, via: "Text",
        answer: agent.texts? ? "To reply, use send_text to #{texter}; ending your turn does not reply." : "You have no phone number here to text back from." }
    end

    # The number that texted, when this is voip.ms forwarding a text.
    def texter
      @texter ||= (mail.from&.first.to_s.downcase == TEXT_SENDER && mail.subject.to_s[TEXT_SUBJECT, 1]) || nil
    end

    # Its files are listed above its words, which may be cut for length.
    def text(addressed, listing, routed_from: nil, blind: nil, answered: nil)
      body = body_text
      sent_to = addressed.map { "Sent to #{it.email_address}, the address of #{it.name}, which now comes to you.\n" }.join
      sent_to += "Sent to #{routed_from.email_address}, the address of #{routed_from.name}; routed here by the workspace's contact routing.\n" if routed_from
      "#{"In #{found_in.join(", ")}:\n" if found_in}Subject: #{mail.subject}\nDate: #{mail.date}\n#{recipients(blind)}#{sent_to}#{"#{answered}\n" if answered}#{listing}\n#{body.to_s.strip}"
    end

    def body_text
      @body_text ||= if mail.multipart? then mail.text_part&.decoded || html_text(mail.html_part&.decoded)
      elsif ReceivedMail::Files.file?(mail) then nil
      elsif mail.mime_type == "text/html" then html_text(mail.decoded)
      else mail.decoded
      end
    end

    # Who else it went to and where a reply goes, so the agent copies no one
    # twice. A header the message lacks is left out.
    def recipients(blind)
      { "To" => mail[:to], "Cc" => mail[:cc], "Bcc" => blind, "Reply-To" => mail[:reply_to] }
        .filter_map { |name, value| "#{name}: #{value}\n" if name == "To" || value.to_s.present? }.join
    end

    # Mail that reached the agent with none of its addresses in To or Cc came
    # as a blind copy to it: the catch-all found it by its envelope
    # (AgentsMailbox); its own box holds only its own account's mail. Other
    # blind copies never arrive, so none is shown. A mailbox it reads for
    # someone else does not prove a blind copy to the agent's address.
    def blind_copy_to(agents)
      return if found_in || gmail?
      own = agents.flat_map { [ it.email_address, it.mail_account&.then { it.address unless it.read_only? } ] }.compact.map(&:downcase)
      return if (Array(mail.to) + Array(mail.cc)).map(&:downcase).intersect?(own)
      envelope = %w[ Delivered-To X-Original-To ].flat_map { |name| Array(mail.header[name]).map { it.value.to_s.downcase } }
      (envelope & own).first || own.find { it == agents.first.mail_account&.address }
    end

    def files = @files ||= ReceivedMail::Files.new(mail)

    def html_text(html) = ActionView::Base.full_sanitizer.sanitize(html.to_s).gsub(/\n{3,}/, "\n\n")
end
