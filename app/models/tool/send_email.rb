# Sends mail from the agent's own address: its address here, or its own mail
# account's (Agent::MailAccount). Mail to the install's admitted
# people goes at once; to anyone else the person approves the exact message
# first, as with any tool that reaches outside. Files from the agent's
# computer go with it: the card names each, and the approval holds to their
# bytes, so a file changed after it is approved asks again. Mail that leaves
# the install's people outside the agent's sending hours is held for them
# (HeldEmail), and the call says when it goes. Mail that goes now is sent
# once (Tool::SendsMailOnce): a server that takes it and never answers is
# asked nothing more, and its own account's Sent folder is looked in. With
# more than one address of its own, it may name the one a message goes from
# (#618); asking is the same whichever it names.
class Tool::SendEmail < Tool
  prepend Tool::AsksEverySend
  include Tool::Attaching
  include Tool::SendsMailOnce


  description "Send an email from your own address. To reply to an email you were sent, pass its message id as in_reply_to " \
    "and keep its subject with Re: in front, so it stays in the same thread. Mail on a subject you already have a thread about with " \
    "them is refused without in_reply_to, unless you pass new_thread: true. Mail may wait for the person's approval."
  ADDRESSES = { items: { type: "string", pattern: "^[^@\\s<>,]+@[^@\\s<>,]+$", maxLength: 254 }, max_items: 10 }.freeze
  argument :to, :array, **ADDRESSES, min_items: 1
  argument :cc, :array, **ADDRESSES, required: false, description: "Addresses to copy, shown to every recipient."
  argument :bcc, :array, **ADDRESSES, required: false, description: "Addresses to copy unseen by the other recipients."
  argument :subject, :string, min_length: 1, max_length: 200
  argument :body, :string, min_length: 1, max_length: 64_000, description: DurableAssistants::EmailBody::DESCRIPTION
  argument :in_reply_to, :string, required: false, max_length: 998, pattern: "^[^<>\\s]+$",
    description: "The message id of the email this answers, as it was given to you."
  argument :new_thread, :boolean, required: false,
    description: "True only when this starts a new conversation, though you have a thread with them on this subject."
  argument :from, :string, required: false, max_length: 254,
    description: "Which of your own addresses it goes from, where you have more than one. Left out, your usual one."
  argument :attachments, :array, required: false, items: { type: "string", minLength: 1, maxLength: 1_024 }, max_items: 10, unique_items: true,
    description: "Paths of files on your computer to attach, up to 10."
  reads_files :attachments, each: -> { Tool::Attaching.limits[:each] }, total: -> { Tool::Attaching.limits[:total] }
  asks :approval
  always_with_recipients
  reaches_others
  effect :external

  # Only mail that leaves the install's own people waits for a person.
  def asks = leaves_install? ? super : nil

  # The arguments are the whole of what the model chooses: the schema refuses
  # any other (Tool.schema). Its own Cc and Bcc are recipients like To, asked
  # about and held alike; the owner's forced Bcc is added by AgentMailer, out
  # of its sight.
  def permitted? = agent.sends_email?

  # Every address it goes to, Cc and Bcc too: an Always for one recipient
  # never lets another ride along unseen.
  def recipients = arguments.values_at("to", "cc", "bcc").flatten.compact.map { it.strip.downcase }.uniq

  # The card shows the message with its files' names and sizes, and the
  # approval binds their bytes (Invocation#changed_since_approved?).
  def previews? = attached_paths.any?

  def preview
    found = attached_files
    return { "error" => "#{missing(found)} didn't arrive from the computer. Ask the agent to send again." } if missing(found)
    { **arguments.slice("from", "to", "cc", "bcc"), "subject" => arguments["subject"], "attachments" => attachments_shown(found),
      "body" => arguments["body"], "digest" => attachments_digest(found) }
  end

  # A reply sent as a new email, out of its thread: refused before anyone is
  # asked (Invocation#begin_work).
  def refusal
    return unknown_sender if unknown_sender
    return if arguments["in_reply_to"] || arguments["new_thread"]
    earlier = Tool::SendEmail::EarlierMail.new(agent, arguments).message_id or return
    "Nothing was sent: you have a thread with them on this subject. Reply in it by passing in_reply_to #{earlier}, " \
      "or, if this really starts a new conversation, send again with new_thread: true."
  end

  def call(to:, subject:, body:, cc: [], bcc: [], in_reply_to: nil, new_thread: false, from: nil, attachments: [])
    refuse_unsendable
    found = attached_files
    raise Tool::Refusal, "#{missing(found)} didn't arrive from your computer, so nothing was sent. Send again." if missing(found)
    if leaves_install? && (opening = agent.held_until)
      invocation.create_held_email!(conversation: invocation.conversation, send_at: opening)
      return { held: to, sendsAt: opening.iso8601,
        why: "Outside your sending hours (#{agent.sending_hours_label}), so it goes then, unless the person cancels it. You will be told." }
    end
    send_once(to: to, sender: sender, domain: sender.split("@").last, tool_name: self.class.tool_name,
      parts: [ to, cc, bcc, subject, body, in_reply_to, attachments_digest(found) ]) do |message_id|
      deliver(found, message_id: message_id)
      { sent: to, messageId: message_id, attached: (found.map(&:name) if found.any?) }.compact
    end
  end

  def self.dispatch_words(arguments)
    Dispatch::Words.new(noun: "email", to: Array(arguments["to"]).to_sentence, excerpt: arguments["subject"].to_s,
      provider: "the Sent folder of the account it went from", log: "the Sent folder for its Message-ID, or ask the recipient")
  end

  # Mail held for the sending hours, as it was allowed (HeldEmail#send_now).
  def send_held
    raise Tool::Refusal, "#{agent.name} can't send email any more." unless permitted?
    raise Tool::Refusal, contact_refusal if contact_refusal
    refuse_unsendable
    found = attached_files
    raise Tool::Refusal, "#{missing(found)} is no longer with it." if missing(found)
    deliver(found)
  end

  private
    def attaching_arguments = arguments

    # The address it goes from: the one it named, or its own account's where
    # it can send through it, else its address here, as before.
    def sender = arguments["from"]&.strip&.downcase || (agent.mail_account.address if agent.own_mail?) || agent.email_address

    def unknown_sender
      return if arguments["from"].nil? || agent.sending_addresses.include?(sender)
      "Nothing was sent: #{sender} is not an address you send from. You send from #{agent.sending_addresses.to_sentence}."
    end

    def leaves_install? = !recipients.all? { Admission.listed?(it) }

    def deliver(found, message_id: nil)
      AgentMailer.message_from(agent, to: arguments["to"], cc: arguments["cc"].to_a, bcc: arguments["bcc"].to_a, subject: arguments["subject"], body: arguments["body"],
        in_reply_to: arguments["in_reply_to"], files: found.map { [ it.name, it.file.download ] }, message_id: message_id, from: sender).deliver_now
        .tap { invocation.uploads.destroy_all }
    rescue *Tool::SendsMailOnce::MAY_HAVE_GONE => problem
      raise Unanswered, problem.class.name
    rescue Agent::MailAccount::SignInError => error
      cannot_sign_in(error)
    rescue Agent::MailAccount::ReadOnly => error
      refused(error)
    end

    # Mail leaves only through the agent's own sending account; never one it
    # only reads, nor, where that account is its only address, its address
    # here: checked before anything is held or sent, and again in AgentMailer.
    def refuse_unsendable
      raise Tool::Refusal, unknown_sender if unknown_sender
      account = agent.mail_account
      account&.refuse_sending!
      account&.refuse_unusable!
    rescue Agent::MailAccount::SignInError => error
      cannot_sign_in(error)
    rescue Agent::MailAccount::ReadOnly => error
      refused(error)
    end

    def cannot_sign_in(error)
      raise Tool::Refusal, "Your mail account couldn't sign in, so nothing was sent: #{error.message}"
    end

    def refused(error)
      raise Tool::Refusal, "#{error.message.delete_suffix(".")}, so nothing was sent."
    end
end
