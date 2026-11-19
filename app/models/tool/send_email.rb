# Sends mail from the agent's own address: its address here, or its own mail
# account's (Agent::MailAccount). Mail to the install's admitted
# people goes at once; to anyone else the person approves the exact message
# first, as with any tool that reaches outside. Files from the agent's
# computer go with it: the card names each, and the approval holds to their
# bytes, so a file changed after it is approved asks again. Mail that leaves
# the install's people outside the agent's sending hours is held for them
# (HeldEmail), and the call says when it goes. Mail that goes now is sent
# once (Tool::SendsMailOnce): a server that takes it and never answers is
# asked nothing more, and its own account's Sent folder is looked in.
class Tool::SendEmail < Tool
  prepend Tool::AsksEverySend
  include Tool::Attaching
  include Tool::SendsMailOnce

  # The server may have taken the message: these come only once a
  # connection is open, and may come after the message was on its way.
  # Anything else (refused, unreachable, a 4xx or 5xx) sent nothing.
  MAY_HAVE_GONE = [ Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE ].freeze

  description "Send an email from your own address. To reply to an email you were sent, pass its message id as in_reply_to " \
    "and keep its subject with Re: in front, so it stays in the same thread. Mail may wait for the person's approval."
  ADDRESSES = { items: { type: "string", pattern: "^[^@\\s<>,]+@[^@\\s<>,]+$", maxLength: 254 }, max_items: 10 }.freeze
  argument :to, :array, **ADDRESSES, min_items: 1
  argument :cc, :array, **ADDRESSES, required: false, description: "Addresses to copy, shown to every recipient."
  argument :bcc, :array, **ADDRESSES, required: false, description: "Addresses to copy unseen by the other recipients."
  argument :subject, :string, min_length: 1, max_length: 200
  argument :body, :string, min_length: 1, max_length: 64_000, description: "Plain text."
  argument :in_reply_to, :string, required: false, max_length: 998, pattern: "^[^<>\\s]+$",
    description: "The message id of the email this answers, as it was given to you."
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
    { **arguments.slice("to", "cc", "bcc"), "subject" => arguments["subject"], "attachments" => attachments_shown(found),
      "body" => arguments["body"], "digest" => attachments_digest(found) }
  end

  def call(to:, subject:, body:, cc: [], bcc: [], in_reply_to: nil, attachments: [])
    refuse_unsendable
    found = attached_files
    raise Tool::Refusal, "#{missing(found)} didn't arrive from your computer, so nothing was sent. Send again." if missing(found)
    if leaves_install? && (opening = agent.held_until)
      invocation.create_held_email!(conversation: invocation.conversation, send_at: opening)
      return { held: to, sendsAt: opening.iso8601,
        why: "Outside your sending hours (#{agent.sending_hours_label}), so it goes then, unless the person cancels it. You will be told." }
    end
    account = agent.mail_account if agent.own_mail?
    sender = account&.address || agent.email_address
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

  # Whether its own account's Sent folder holds a message whose server never
  # answered (Dispatch#check): only the account it went through, and only
  # that message. Its Message-ID when it does, nil when not yet.
  def self.find_dispatched(dispatch)
    account = sent_through(dispatch) or raise Dispatch::LookupFailed, "no Sent folder may be read"
    dispatch.provider_id if account.sent?(dispatch.provider_id)
  rescue Agent::MailAccount::SentFolder::Unreadable => problem
    raise Dispatch::LookupFailed, problem.message
  end

  # The agent's own account it went through, if it is still the one it
  # sends from and its Sent folder can be read. Never the install's shared
  # mailbox: mail that went the install's way has no Sent folder to ask.
  def self.sent_through(dispatch)
    account = dispatch.agent.mail_account
    account if account&.address == dispatch.sender && account.reads_sent?
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

    def leaves_install? = !recipients.all? { Admission.listed?(it) }

    def sent_folder?(dispatch) = self.class.sent_through(dispatch).present?
    def find_dispatched(dispatch) = self.class.find_dispatched(dispatch)

    def deliver(found, message_id: nil)
      AgentMailer.message_from(agent, to: arguments["to"], cc: arguments["cc"].to_a, bcc: arguments["bcc"].to_a, subject: arguments["subject"], body: arguments["body"],
        in_reply_to: arguments["in_reply_to"], files: found.map { [ it.name, it.file.download ] }, message_id: message_id).deliver_now
        .tap { invocation.uploads.destroy_all }
    rescue *MAY_HAVE_GONE => problem
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
