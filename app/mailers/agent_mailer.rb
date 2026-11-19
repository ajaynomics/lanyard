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
  # message_id: the Message-ID the call chose and recorded before sending
  # (Dispatch), by which its Sent folder is asked whether it went.
  def message_from(agent, to:, subject:, body:, cc: [], bcc: [], in_reply_to: nil, files: [], message_id: nil)
    @body = body
    account = agent.mail_account
    account&.refuse_sending!
    account&.refuse_unusable!
    own = @sent_through = account if agent.own_mail?
    headers["In-Reply-To"] = headers["References"] = "<#{in_reply_to}>" if in_reply_to
    headers["Message-ID"] = "<#{message_id}>" if message_id
    files.each_with_index { |(name, bytes), index| attachments[attachments[name] ? "#{index + 1}-#{name}" : name] = bytes }
    mail from: own&.from || email_address_with_name(agent.email_address, agent.name), to: to, cc: cc.presence,
      bcc: [ *bcc, account&.forced_bcc ].compact.uniq.presence, subject: subject,
      delivery_method_options: own&.delivery_options || agent.workspace.mail_domain&.delivery_options do |format|
      format.text { render plain: body }
    end
  end
end
