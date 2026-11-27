# Mail of the last 30 days that a new email belongs with: the same subject,
# less any Re: or Fwd:, and someone in common. An agent twice answered a
# client as a new email, once under a new subject; Tool::SendEmail refuses
# that now. Read from what Rails already keeps, never the mail server: mail
# the agent received, as its thread recorded it (ReceivedMail, whose request
# id carries the Message-ID), and mail it sent (its send_email calls, in any of its conversations). The
# same words sent again are not a new thread: Tool::SendsMailOnce answers those.
class Tool::SendEmail::EarlierMail
  WINDOW = 30.days
  PREFIXES = /\A(?:\s*(?:re|fwd?|fw)\s*:)+/i
  ADDRESS = /[^\s<>,;"]+@[^\s<>,;"]+/
  WORDS = %w[ to cc bcc subject body ].freeze
  Found = Data.define(:message_id, :subject, :addresses, :at)

  def self.subject(text) = text.to_s.sub(PREFIXES, "").squish.downcase

  def initialize(agent, arguments)
    @agent, @arguments = agent, arguments
  end

  # The Message-ID of the newest such mail, or nil.
  def message_id
    wanted, addresses = self.class.subject(@arguments["subject"]), addresses_in(@arguments.values_at("to", "cc", "bcc"))
    (received + sent).select { self.class.subject(it.subject) == wanted && it.addresses.intersect?(addresses) }.max_by(&:at)&.message_id
  end

  private
    def received
      @agent.conversation.messages.where(role: "user", created_at: WINDOW.ago..).where("request_id LIKE ?", "email:#{@agent.id}:%").filter_map do |message|
        headers = message.content.to_s[/^Subject: .*?(?=\n\n|\z)/m] or next
        people = [ message.sender, *headers.scan(/^(?:To|Cc|Reply-To): (.*)$/).flatten ]
        Found.new(message.request_id.split(":", 3).last, headers[/\ASubject: (.*)$/, 1], addresses_in(people), message.created_at)
      end
    end

    def sent
      @agent.invocations.succeeded.where(tool_name: "send_email", created_at: WINDOW.ago..).filter_map do |call|
        id = call.result.try(:[], "messageId") or next
        next if call.arguments.slice(*WORDS) == @arguments.slice(*WORDS)
        Found.new(id, call.arguments["subject"], addresses_in(call.arguments.values_at("to", "cc", "bcc")), call.created_at)
      end
    end

    def addresses_in(texts) = texts.flatten.compact.join(" ").scan(ADDRESS).map(&:downcase).uniq
end
