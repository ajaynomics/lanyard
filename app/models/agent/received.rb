# What reached an agent from others since a time, one row for every channel
# (issue #43): an agent that checked one channel and said nobody had answered
# missed the answer waiting on another. Read from its own thread's copy
# (Message#incoming), so only its own mail, each sender marked as the thread
# marks it. A channel it lacks says "not connected", never "none".
class Agent::Received
  CHANNELS = %w[ Email Concourse Campfire Telegram Text ].freeze
  LISTED = 20

  Said = Data.define(:id, :channel, :sender, :at, :untrusted, :subject)

  # An email's subject, the first line ReceivedMail writes above its words.
  SUBJECT = /\A(?:In [^\n]*:\n)?Subject: ([^\n]*)/

  # unverified: the channel's own last check failed, or never ran, so its count may be short.
  Row = Data.define(:channel, :connected, :messages, :checked_through, :unseen, :unverified) do
    def status
      return "not connected" if !connected && messages.none?
      return "unverified/#{messages.size}" if unverified
      messages.any? ? messages.size.to_s : "none"
    end
  end

  def initialize(agent, since:)
    @agent, @since = agent, since
  end

  def to_h
    { since: local(@since), summary: rows.map { "#{it.channel}: #{it.status}" }.join("; "), channels: rows.map { row_json(it) } }
  end

  private
    def rows
      @rows ||= CHANNELS.map { |channel| row(channel, incoming.select { it.channel == channel }) }
    end

    def row(channel, messages)
      case channel
      when "Email" then from_mail(messages)
      when "Text"
        Row.new(channel, @agent.texts? && DurableAssistants::Email.inbox?, messages, Time.current,
          "Texts arrive through the install's mailbox, which is read every minute.", false)
      when "Campfire"
        Row.new(channel, @agent.campfire_bot.present? && @agent.campfire.configured?, messages, Time.current,
          "Messages in rooms that don't mention its bot.", false)
      when "Telegram"
        Row.new(channel, !!@agent.telegram_bot&.usable?, messages, Time.current,
          "Group posts that neither mention nor answer the bot: every one that reaches the bot is stored, and telegram_messages " \
            "reads them; only a mention or a reply wakes you. With privacy mode on, Telegram sends the bot only mentions and replies.", false)
      when "Concourse" then from_concourse(messages)
      end
    end

    # Names the boxes actually read for it: its own (Agent::MailAccount::Inbox)
    # and the install's, unless its own is its only address. Nothing here
    # knows of mail waiting, so it says only when each was last read; one that
    # failed says why, and the count is unverified, as Concourse's is.
    def from_mail(messages)
      own = @agent.mail_accounts.reading.to_a
      install = DurableAssistants::Email.inbox? && own.none?(&:primary?)
      boxes = own.map(&:address) + (install ? [ "the install's mailbox (#{@agent.email_address})" ] : [])
      failed = own.select { it.inbox_error.present? }
      reads = own.map { it.read_only? ? it.folders.map(&:read_at).compact.min : it.inbox_read_at }
      Row.new("Email", boxes.any?, messages, (reads.all? ? reads.compact.min || Time.current : nil),
        failed.any? ? failed.map { "#{it.address} couldn't be read at its last check: #{it.inbox_error}" }.join(" ") :
          "Mail reaches it from #{boxes.to_sentence}, each read every minute; anything after its last read is not here yet.",
        failed.any? || !reads.all?)
    end

    # Each network's sweep says when it last read Concourse, and whether it could.
    def from_concourse(messages)
      networks = @agent.concourse_networks
      errors = networks.filter_map(&:check_error)
      checks = networks.map(&:checked_at)
      Row.new("Concourse", networks.any? && DurableAssistants::Concourse.configured?, messages, (checks.min if checks.all?),
        errors.any? ? "Concourse couldn't be read at its last check: #{errors.to_sentence}" : "Tasks after its last check, which runs every minute.",
        errors.any? || !checks.all?)
    end

    # Messages from others, when each reached the thread.
    def incoming
      @incoming ||= @agent.conversation.messages.where(role: "user", created_at: @since..).where("content LIKE '[%'").order(:entry_id)
        .filter_map { |message| message.incoming&.then { Said.new(message.id, it.channel, it.sender, message.created_at, !it.trusted, subject(it)) } }
    end

    def row_json(row)
      return { channel: row.channel, status: row.status } if row.status == "not connected"
      { channel: row.channel, status: row.status, checkedThrough: row.checked_through&.then { local(it) }, unseen: row.unseen,
        messages: row.messages.last(LISTED).map { { id: it.id, from: it.sender, subject: it.subject, at: local(it.at), untrusted: it.untrusted }.compact } }
    end

    def subject(incoming) = (incoming.body[SUBJECT, 1].to_s.strip.truncate(200).presence if incoming.channel == "Email")

    def local(time) = time.in_time_zone(@agent.time_zone).iso8601
end
