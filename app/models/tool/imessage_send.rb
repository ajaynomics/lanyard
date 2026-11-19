# Sends iMessages from the person's own phone, one bubble after another. It
# goes out in their name to people they know, so the person approves every
# send, with the chat and the exact words, even where the install allows
# everything. Then it reads the chat back and says what arrived. It never
# sends again on its own: each call is recorded (Dispatch) before its first
# bubble goes, and a bubble BlueBubbles never confirmed is looked for in the
# chat, then and in the background, until it is known.
class Tool::ImessageSend < Tool
  prepend Tool::AsksEverySend
  include Tool::Imessage

  DELIVERY_WAIT = 10 # seconds to watch for delivery after the last bubble
  # A bubble BlueBubbles took but never confirmed, not yet in the chat. Not
  # a failure, which an agent would send again.
  UNCONFIRMED = "Unknown: BlueBubbles didn't confirm the bubble marked unknown, and the chat doesn't show it yet, so it may have gone. " \
    "Don't send it again: it is being checked, and you'll be told here whether it went. Those after it were not sent.".freeze

  description "Send iMessages from the person's own phone into one chat, as one or more bubbles in order. " \
    "The person approves every send. Afterwards it says which bubbles were delivered. If the result is uncertain, " \
    "read the chat with imessage_history and tell the person; never send the same words again on your own."
  argument :chat, :string, pattern: Tool::Imessage::GUID, max_length: 200, description: "The chat's GUID, from imessage_chats."
  argument :bubbles, :array, items: { type: "string", minLength: 1, maxLength: 4000 }, min_items: 1, max_items: 10,
    description: "The words, each its own bubble, sent in this order."
  asks :approval, every_time: true
  reaches_others

  # Whom it goes to, as the chat was last listed, with every bubble below.
  def self.approval_title(arguments)
    chat = DurableAssistants::Bluebubbles.label(arguments["chat"])
    people = chat[:participants].presence&.join(", ")
    to = people && people != chat[:name] ? "#{chat[:name]} (#{people})" : chat[:name]
    "Send #{arguments["bubbles"].to_a.size == 1 ? "an iMessage" : "#{arguments["bubbles"].size} iMessages"} to #{to}?"
  end

  # A chat with one person is named by their address or number; a group's
  # people are only names here, so a group is not checked.
  def contacts = [ arguments["chat"].to_s[/;-;(.+)\z/, 1] ].compact

  def call(chat:, bubbles:)
    raise Tool::Refusal, "There is no chat #{chat}. Find it with imessage_chats." unless call_bluebubbles { bluebubbles.chat(chat) }
    fingerprint = Dispatch.fingerprint(self.class.tool_name, chat, *bubbles)
    refuse_repeat(chat, fingerprint)
    # Recorded before the first bubble goes; a call that has one already was tried, and never sends again.
    dispatch = Dispatch.record(invocation, tool_name: self.class.tool_name, sender: chat, fingerprint: fingerprint) or
      return tried(invocation.reload_dispatch, chat)

    sent = []
    bubbles.each_with_index do |text, index|
      sent << bubbles_sent(text, bluebubbles.send_text(chat, text))
    rescue DurableAssistants::Bluebubbles::Unknown
      found = in_chat(dispatch, text, sent)
      next sent << bubbles_sent(text, found) if found
      dispatch.checking!
      return { chat: chat, bubbles: [ *delivered(chat, sent), { text: text, status: "unknown" }, *bubbles.drop(index + 1).map { { text: it, status: "not sent" } } ],
               key: dispatch.key, note: UNCONFIRMED }
    rescue DurableAssistants::Bluebubbles::Error => error
      # Those before it went, so the call did send: the same words again soon are refused.
      sent.any? ? dispatch.confirm(sent.last[:guid]) : dispatch.refused
      raise Tool::Refusal, stopped(sent, bubbles, index, "#{error.message}: it was not sent")
    end
    dispatch.confirm(sent.last[:guid])
    { chat: chat, bubbles: delivered(chat, sent) }
  end

  def self.dispatch_words(arguments)
    Dispatch::Words.new(noun: "iMessage", to: DurableAssistants::Bluebubbles.label(arguments["chat"])[:name],
      excerpt: Array(arguments["bubbles"]).join(" / "), provider: "BlueBubbles", log: "the chat in Messages on the phone")
  end

  # The GUID of the last bubble a dispatch recorded, once the chat shows
  # every bubble up to the one BlueBubbles never confirmed (Dispatch#check);
  # nil until then.
  def self.find_dispatched(dispatch)
    bubbles = dispatch.invocation.call_arguments["bubbles"]
    # As the call reported it; a call lost mid-send reported none, so any may have gone.
    doubted = Array(dispatch.invocation.result.try(:dig, "bubbles")).index { it["status"] == "unknown" } || bubbles.size - 1
    went = in_order(bubbles, mine(dispatch.sender, since: dispatch.created_at))
    went.last[:guid] if went.size > doubted
  rescue DurableAssistants::Bluebubbles::Error => error
    raise Dispatch::LookupFailed, error.message
  end

  # The person's own messages in a chat since a send began, oldest first,
  # leaving out any Messages marked failed. A minute early, for the Mac's clock.
  def self.mine(chat, since:)
    DurableAssistants::Bluebubbles.messages(chat, limit: 50, after: since - 1.minute)[:messages].select { it[:from_me] && it[:error].zero? }.reverse
  end

  # The bubbles the chat shows, in order from the first, each the next of
  # the person's messages with its words.
  def self.in_order(bubbles, messages)
    bubbles.each_with_object([]) do |text, went|
      at = messages.index { it[:text] == text.strip } or break went
      went << messages[at]
      messages = messages.drop(at + 1)
    end
  end

  private
    def bubbles_sent(text, message) = { text: text, guid: message[:guid], status: message[:delivered] ? "delivered" : "sent" }

    # The bubble BlueBubbles never confirmed, if the chat shows it already.
    def in_chat(dispatch, text, sent)
      self.class.mine(dispatch.sender, since: dispatch.created_at).reject { it[:guid].in?(sent.pluck(:guid)) }.find { it[:text] == text.strip }
    rescue DurableAssistants::Bluebubbles::Error
      nil
    end

    # What the call answers once its send was tried: not sent, sent, or not
    # known yet, with the key it is checked under, after one more look.
    def tried(dispatch, chat)
      raise Tool::Refusal, "These iMessages to #{chat} were not sent." if dispatch.not_sent?
      dispatch.look_up unless dispatch.settled?
      if dispatch.sent?
        { chat: chat, note: "Sent once already, so not sent again. Read the chat with imessage_history to see what arrived." }
      else
        { chat: chat, key: dispatch.key, note: UNCONFIRMED }
      end
    end

    # The same bubbles to the same chat, just sent, still being checked or
    # still unknown: the agent retrying a send that went, or may have.
    def refuse_repeat(chat, fingerprint)
      earlier = agent.dispatches.repeated(fingerprint, by: invocation) or return
      at = Conversation.stamp(earlier.created_at, agent.time_zone)
      if earlier.sent?
        raise Tool::Refusal, "These same iMessages went to #{chat} at #{at}, so they weren't sent again."
      elsif earlier.unknown?
        raise Tool::Refusal, "These same iMessages to #{chat}, sent at #{at}, may have gone and whether they did is still unknown " \
          "(key #{earlier.key}), so they weren't sent again. Ask your person to check the chat on the phone and say on its card whether they went."
      else
        raise Tool::Refusal, "These same iMessages to #{chat}, sent at #{at}, may have gone and are still being checked (key #{earlier.key}), " \
          "so they weren't sent again. You'll be told here whether they went."
      end
    end

    # What arrived, watched for a few seconds: iMessage reports delivery, a
    # text sent as SMS never does, so "sent" is as far as some ever get.
    def delivered(chat, sent)
      deadline = DELIVERY_WAIT.seconds.from_now
      while sent.any? { it[:status] == "sent" } && Time.current < deadline
        sleep 2
        seen = bluebubbles.messages(chat, limit: 25)[:messages].index_by { it[:guid] }
        sent.each { |bubble| bubble[:status] = "delivered" if bubble[:status] == "sent" && seen.dig(bubble[:guid], :delivered) }
      end
      sent.map { it.except(:guid) }
    rescue DurableAssistants::Bluebubbles::Error
      sent.map { it.except(:guid) }
    end

    def stopped(sent, bubbles, index, why)
      went = sent.map { "\"#{it[:text].truncate(60)}\" (#{it[:status]})" }
      [ "Bubble #{index + 1}, \"#{bubbles[index].truncate(60)}\": #{why}.",
        ("Before it: #{went.join(", ")}." if went.any?),
        ("Not sent after it: #{bubbles.size - index - 1}." if index < bubbles.size - 1),
        "Read the chat with imessage_history and tell the person; don't send again on your own." ].compact.join(" ")
    end
end
