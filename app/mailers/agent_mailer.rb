# Mail an agent sends, from its own address (Tool::SendEmail). A reply carries
# the message it answers in In-Reply-To and References, so it lands in the
# same thread of mail.
class AgentMailer < ApplicationMailer
  layout false

  # Mail its own account's server took is filed in that account's Sent
  # folder (Agent::MailAccount::SentFolder#file_in_sent), as it was sent.
  # Only after the server answered: a delivery that raised skips this.
  after_deliver { @sent_through&.file_in_sent(message.encoded) }

  # To its own person, when it waits on them and they have no device to
  # notify (Conversation::Notifiable): what a notice would say, and the way back.
  # The app's notice rather than the agent's words, so it goes the install's
  # way even where the agent has its own account: it must arrive while the
  # vault is down, and its link into the thread is for the workspace's people,
  # not the forced Bcc. Where its workspace has its own mail domain, it goes
  # from there, through that domain's server (Workspace::MailDomain); a vault
  # that can't be read then is tried again (MailDeliveryJob).
  def needs_you(conversation, to:, title:, body:)
    @body = body
    @url = conversation_url(conversation, **conversation.agent.workspace.brand.url_options)
    agent = conversation.agent
    mail from: email_address_with_name(agent.email_address, agent.name), to: to, subject: title,
      delivery_method_options: agent.workspace.mail_domain&.delivery_options do |format|
      format.text { render plain: "#{@body}\n\nAnswer it here: #{@url}\n" }
    end
  end

  # files: [name, bytes] pairs; a name used twice is told apart, as a mail
  # program would otherwise keep only one.
  #
  # With its own mail account (Agent::MailAccount) it goes from that address
  # through that server, signed in for this message alone; otherwise from its
  # address here, through its workspace's own mail server where it has one,
  # or else the install's. The owner's forced Bcc goes either
  # way, added here so no argument of the agent's can drop it. A mailbox it
  # only reads is never one it sends through: Agent#mail_account is never one,
  # and were it, nothing would be sent. Where the account is its only address
  # (primary), mail it can't send through it is not sent at all.
  #
  # from: the one of its addresses the call named (Agent#sending_addresses),
  # which picks the way it goes; nil, its own account's where it has one, as
  # before. The From line is always one of its own. An account it sends from
  # only when named (Agent#named_mail_accounts) is used, with its own server,
  # only when from names it; never when from is left out. Its own Bcc goes
  # beside the default account's, which naming another never escapes.
  #
  # message_id: the Message-ID the call chose and recorded before sending
  # (Dispatch), by which its Sent folder is asked whether it went.
  def message_from(agent, to:, subject:, body:, cc: [], bcc: [], in_reply_to: nil, files: [], message_id: nil, from: nil)
    account = agent.named_mail_accounts.find { it.address == from } || agent.mail_account
    account&.refuse_sending!
    account&.refuse_unusable!
    raise ArgumentError, "#{agent.name} does not send from #{from}" unless from.nil? || agent.sending_addresses.include?(from)
    own = @sent_through = account if account&.usable? && from.in?([ nil, account.address ])
    headers["In-Reply-To"] = headers["References"] = "<#{in_reply_to}>" if in_reply_to
    headers["Message-ID"] = "<#{message_id}>" if message_id
    files.each_with_index { |(name, bytes), index| attachments[attachments[name] ? "#{index + 1}-#{name}" : name] = bytes }
    mail from: own&.from || email_address_with_name(agent.email_address, agent.name), to: to, cc: cc.presence,
      bcc: [ *bcc, account&.forced_bcc, agent.mail_account&.forced_bcc ].compact.uniq.presence, subject: subject,
      delivery_method_options: own&.delivery_options || agent.workspace.mail_domain&.delivery_options do |format|
      written(format, body)
    end
  end

  # A draft for its own account's Drafts folder (Tool::SaveDraft), written as
  # message_from writes a message, for its person to send from their own mail
  # program. Never delivered, so no server and no Bcc: what they send is theirs.
  def draft(account, to:, subject:, body:, cc: [], in_reply_to: nil)
    headers["In-Reply-To"] = headers["References"] = "<#{in_reply_to}>" if in_reply_to
    mail(from: account.from, to: to, cc: cc.presence, subject: subject) { written(it, body) }
  end

  # An event's invitation or cancellation (CalendarInvite, #261), from the
  # address message_from would use (Agent#invitation_address): the event's
  # ORGANIZER, where the guests' answers come back. As RFC 6047 asks, the iCalendar object rides
  # in a text/calendar part whose Content-Type carries the same method as its
  # own METHOD line, under a plain-text part for anything that can't read it;
  # it goes as an attachment as well, which is what Google's and Outlook's
  # mail expect before they offer the buttons.
  def invitation(agent, invite, message_id: nil)
    account = agent.mail_account
    account&.refuse_sending!
    account&.refuse_unusable!
    own = @sent_through = account if agent.own_mail?
    headers["Message-ID"] = "<#{message_id}>" if message_id
    attachments["invite.ics"] = { mime_type: "application/ics", content: invite.ics }
    mail(from: own&.from || email_address_with_name(agent.email_address, agent.name), to: invite.attendees,
      bcc: account&.forced_bcc, subject: invite.subject,
      delivery_method_options: own&.delivery_options || agent.workspace.mail_domain&.delivery_options) do |format|
      format.text { render plain: invite.body }
      format.ics { render plain: invite.ics }
    end.tap { say_method(it, invite.ical_method) }
  end

  private
    def written(format, body)
      email_body = DurableAssistants::EmailBody.new(body)
      format.text(content_transfer_encoding: DurableAssistants::EmailBody::TEXT_ENCODING) { render plain: email_body.encoded_text }
      format.html { render html: email_body.html }
    end

    # Mail's own Content-Type for the part says text/calendar and no more; the
    # method is what tells a mail program this is an invitation rather than a
    # file, so it is put back on.
    def say_method(message, ical_method)
      part = message.all_parts.find { it.mime_type == "text/calendar" } or return
      part.content_type = "text/calendar; charset=UTF-8; method=#{ical_method}"
    end
end
