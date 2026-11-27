# Sends a text from the agent's own number (docs/phone.md). The app picks the
# number; the model names only whom to text and what to say. Each text asks the
# person first unless they allowed it "Always", for everyone or for that number,
# as with email. Past DAILY_LIMIT texts in a day the tool refuses, and the person
# is told once: an agent texting that much is more likely stuck than busy.
class Tool::SendText < Tool
  prepend Tool::AsksEverySend
  DAILY_LIMIT = 20
  LIMITED = "You have sent #{DAILY_LIMIT} texts in the last 24 hours, the most allowed."
  # An unconfirmed text may have gone. Count it as one sent and keep looking
  # it up (Dispatch#check); calling it failed would invite a second send.
  UNCONFIRMED = "Unknown: this text may have gone. " \
    "Don't send it again: it is being checked, and you'll be told here whether it went. " \
    "Tell your person it may not have arrived yet."

  description "Send a text message from your own phone number to one North American number. " \
    "Up to 160 characters goes as one text; longer goes as one MMS. Each text waits for the person's approval " \
    "unless they allowed it always. At most #{DAILY_LIMIT} texts in any 24 hours."
  argument :to, :string, pattern: "^[2-9][0-9]{2}[2-9][0-9]{6}$", description: "Ten digits, no spaces or +1, as 6475550123."
  argument :body, :string, min_length: 1, max_length: DurableAssistants::Voipms::MMS_LIMIT
  asks :approval
  reaches_others
  effect :external

  def permitted? = agent.texts?

  def recipients = [ arguments["to"] ]

  def call(to:, body:)
    if today.where(state: %w[ running succeeded ]).count >= DAILY_LIMIT
      tell_person unless today.where(state: "failed").where("error LIKE ?", "#{LIMITED}%").exists?
      raise Refusal, "#{LIMITED} Tell your person here what you meant to send."
    end
    from = agent.phone_number
    fingerprint = Dispatch.fingerprint(self.class.tool_name, from, to, body)
    refuse_repeat(to, fingerprint)
    # Recorded before voip.ms is asked; a call that has one already was tried, and never sends again.
    dispatch = Dispatch.record(invocation, tool_name: self.class.tool_name, sender: from, fingerprint: fingerprint) or
      return tried(invocation.reload_dispatch, to)
    dispatch.confirm(DurableAssistants::Voipms.send_text(from: from, to: to, body: body, account: agent.voipms_account))
    tried(dispatch, to)
  rescue DurableAssistants::Voipms::Unconfirmed => error
    dispatch.checking!
    tried(dispatch, to, diagnostic: error.message)
  rescue DurableAssistants::Voipms::Error => error
    if error.reason == :server_error then dispatch&.require_provider_check
    else dispatch&.refused
    end
    raise Refusal, error.message
  end

  def self.dispatch_words(arguments)
    Dispatch::Words.new(noun: "text", to: arguments["to"], excerpt: arguments["body"].to_s, provider: "voip.ms", log: "the phone or voip.ms's message log")
  end

  # voip.ms's id for the text a dispatch recorded, from what the number
  # lists (Dispatch#check); nil when it lists no such text.
  def self.find_dispatched(dispatch)
    arguments = dispatch.invocation.call_arguments
    DurableAssistants::Voipms.sent_id(from: dispatch.sender, to: arguments["to"], body: arguments["body"], since: dispatch.created_at,
      account: dispatch.agent.voipms_account)
  rescue DurableAssistants::Voipms::Error => error
    raise Dispatch::LookupFailed, error.message
  end

  private
    # What the call answers for a text it tried: sent, with its id, or not
    # known yet, with the key it is checked under.
    def tried(dispatch, to, diagnostic: nil)
      raise Refusal, DurableAssistants::Voipms::Error::CHECK_BEFORE_RESEND if dispatch.check_before_resend?
      raise Refusal, "This text to #{to} was not sent." if dispatch.not_sent?
      if dispatch.sent? then { sent: to, from: dispatch.sender, id: dispatch.provider_id&.to_i }.compact
      else { unknown: to, from: dispatch.sender, key: dispatch.key, note: UNCONFIRMED, diagnostic: }.compact
      end
    end

    # The same words to the same number may be a retry of a text that went.
    # A server error holds the retry until a person checks the provider.
    def refuse_repeat(to, fingerprint)
      earlier = agent.dispatches.repeated(fingerprint, by: invocation) or return
      raise Refusal, DurableAssistants::Voipms::Error::CHECK_BEFORE_RESEND if earlier.check_before_resend?
      at = Conversation.stamp(earlier.created_at, agent.time_zone)
      if earlier.sent?
        raise Refusal, "This same text went to #{to} at #{at}#{" (voip.ms id #{earlier.provider_id})" if earlier.provider_id}, so it wasn't sent again."
      elsif earlier.unknown?
        raise Refusal, "This same text to #{to}, sent at #{at}, may have gone and whether it did is still unknown (key #{earlier.key}), " \
          "so it wasn't sent again. Ask your person to check the phone or voip.ms's message log and say on its card whether it went."
      else
        raise Refusal, "This same text to #{to}, sent at #{at}, may have gone and is still being checked (key #{earlier.key}), " \
          "so it wasn't sent again. You'll be told here whether it went."
      end
    end

    # Its texts from any of its threads in the last day, this one not counted.
    def today
      agent.invocations.where(tool_name: self.class.tool_name, created_at: 1.day.ago..).where.not(id: invocation.id)
    end

    # Told once, at the first refusal in a day, however often it tries, to
    # everyone in the agent's workspace.
    def tell_person
      agent.workspace.members.each do |member|
        Push.deliver member, kind: "texts", agent: agent, title: "#{agent.name} stopped texting",
          body: "#{agent.name} reached #{DAILY_LIMIT} texts in a day, so I've paused its texts. It can send again as those pass 24 hours.",
          url: Rails.application.routes.url_helpers.conversation_path(conversation), tag: "texts-limit-#{agent.id}"
      end
    end
end
