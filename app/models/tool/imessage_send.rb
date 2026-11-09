# Sends iMessages from the person's own phone, one bubble after another. It
# goes out in their name to people they know, so the person approves every
# send, with the chat and the exact words, even where the install allows
# everything. Then it reads the chat back and says what arrived. It never
# sends again on its own: an outcome nobody knows is reported as that, and a
# call made again after a crash first looks for what already went.
class Tool::ImessageSend < Tool
  include Tool::Imessage

  DELIVERY_WAIT = 10 # seconds to watch for delivery after the last bubble

  description "Send iMessages from the person's own phone into one chat, as one or more bubbles in order. " \
    "The person approves every send. Afterwards it says which bubbles were delivered. If the result is uncertain, " \
    "read the chat with imessage_history and tell the person; never send the same words again on your own."
  argument :chat, :string, pattern: Tool::Imessage::GUID, max_length: 200, description: "The chat's GUID, from imessage_chats."
  argument :bubbles, :array, items: { type: "string", minLength: 1, maxLength: 4000 }, min_items: 1, max_items: 10,
    description: "The words, each its own bubble, sent in this order."
  asks :approval, every_time: true

  # Whom it goes to, as the chat was last listed, with every bubble below.
  def self.approval_title(arguments)
    chat = DurableAssistants::Bluebubbles.label(arguments["chat"])
    people = chat[:participants].presence&.join(", ")
    to = people && people != chat[:name] ? "#{chat[:name]} (#{people})" : chat[:name]
    "Send #{arguments["bubbles"].to_a.size == 1 ? "an iMessage" : "#{arguments["bubbles"].size} iMessages"} to #{to}?"
  end

  def call(chat:, bubbles:)
    raise Tool::Refusal, "There is no chat #{chat}. Find it with imessage_chats." unless call_bluebubbles { bluebubbles.chat(chat) }
    since = (invocation.approval&.created_at || invocation.created_at) - 1.minute
    already = call_bluebubbles { bluebubbles.messages(chat, limit: 50, after: since) }[:messages].select { it[:from_me] }.map { it[:text] }

    sent = []
    bubbles.each_with_index do |text, index|
      if (seen = already.index(text.strip))
        already.delete_at(seen)
        sent << { text: text, status: "already sent" }
        next
      end
      begin
        sent << bubbles_sent(text, bluebubbles.send_text(chat, text))
      rescue DurableAssistants::Bluebubbles::Unknown => error
        raise Tool::Refusal, stopped(sent, bubbles, index, "#{error.message}: it may or may not have gone")
      rescue DurableAssistants::Bluebubbles::Error => error
        raise Tool::Refusal, stopped(sent, bubbles, index, "#{error.message}: it was not sent")
      end
    end
    { chat: chat, bubbles: delivered(chat, sent) }
  end

  private
    def bubbles_sent(text, message) = { text: text, guid: message[:guid], status: message[:delivered] ? "delivered" : "sent" }

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
