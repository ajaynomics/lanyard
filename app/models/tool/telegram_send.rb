# The agent's message in Telegram, posted as its bot (TelegramBot). It goes in
# its own name to groups and people outside the install, so its person
# approves every one, with the chat and the exact words, even where the
# install approves everything, unless they answered "Always for this chat":
# never "Always" for every chat (#150).
#
# Each send is recorded (Dispatch) before Telegram is asked: Telegram can
# take a message and never answer, and a call that only remembered its
# answer would not know whether it sent. Such a send is unknown, never
# failed, and never made again on its own; it stays unknown until a later
# post quotes it (TelegramBot#reveal_send) or a person who looked says
# (#249).
class Tool::TelegramSend < Tool
  # Telegram took the message but never answered, and its Bot API lists
  # nothing a bot has sent. Not a failure, which an agent would send again.
  UNCONFIRMED = "Unknown: Telegram didn't answer in time, and its Bot API lists nothing a bot has sent, so it may have gone. " \
    "Don't send it again: read telegram_messages for this chat to see whether it arrived, and tell your person.".freeze

  description "Send a message as your Telegram bot into one chat: a group the bot is in, or a person who has written to it. " \
    "The person approves every message. If the result says it is unknown whether it went, tell the person; " \
    "never send the same words again on your own: read telegram_messages for the chat instead."
  argument :chat, :integer, description: "The chat's id, as the Telegram message you answer gave it."
  argument :text, :string, min_length: 1, max_length: 4096, description: "Plain text."
  asks :approval, always: false, even_approving_everything: true
  always_with_recipients
  reaches_others
  effect :external

  def permitted? = !!agent.telegram_bot&.usable?

  def recipients = [ "Telegram chat #{arguments["chat"].to_i}" ]

  def approval_title(arguments)
    chat = agent.telegram_bot&.chat_name(arguments["chat"])
    "Send a Telegram message to #{chat || "chat #{arguments["chat"].to_i}"} as #{agent}?"
  end

  def always_label = "Always for this chat"

  def approval_note(_arguments)
    "Telegram messages ask every time, even where everything else is allowed. " \
      "Always for this chat covers #{recipients.sole} only; a message to any other chat still asks."
  end

  def call(chat:, text:)
    bot = agent.telegram_bot
    fingerprint = self.class.fingerprint(bot, chat, text)
    refuse_repeat(chat, fingerprint)
    # Recorded before Telegram is asked; a call that has one already was tried, and never sends again.
    dispatch = Dispatch.record(invocation, tool_name: self.class.tool_name, sender: self.class.sender(bot), fingerprint: fingerprint) or
      return tried(invocation.reload_dispatch, chat)
    dispatch.confirm(bot.say(chat, text))
    tried(dispatch, chat)
  rescue DurableAssistants::Telegram::Unknown
    # Telegram may have posted it, and nothing it offers would say: unknown
    # until a later post quotes it, or a person who looked says.
    dispatch.unconfirmable
    tried(dispatch, chat)
  rescue DurableAssistants::Telegram::Error, TelegramBot::SignInError => error
    # Refused before anything was posted, or never reached: nothing went.
    dispatch&.refused
    raise Refusal, "#{error.message.delete_suffix(".")}, so nothing was sent."
  end

  # One message's identity: the same words to the same chat as the same bot.
  def self.fingerprint(bot, chat, text) = Dispatch.fingerprint(tool_name, sender(bot), Integer(chat), text)

  def self.sender(bot) = "@#{bot.username}"

  # Its sends, oldest last, as the ledger kept them: a call's arguments hold
  # the chat and the words, so a chat's own posts are found without columns
  # of their own (telegram_send is declared, so both are at the top of them). Narrowed as the posts it heard are
  # (TelegramMessage's scopes); every chat when none is named. Never one
  # Telegram refused: nothing went.
  def self.sent_to(agent, chat = nil, saying: nil, between: nil)
    found = agent.dispatches.where(tool_name: tool_name).where.not(state: "not_sent")
    found = found.where("json_extract(invocations.arguments, '$.chat') = ?", Integer(chat)) if chat
    found = found.where("json_extract(invocations.arguments, '$.text') LIKE ? ESCAPE '\\'",
      "%#{Dispatch.sanitize_sql_like(saying)}%") if saying.present?
    found = found.where(created_at: between) if between
    found.order(:created_at)
  end

  def self.dispatch_words(arguments)
    Dispatch::Words.new(noun: "Telegram message", to: "chat #{arguments["chat"].to_i}", excerpt: arguments["text"].to_s,
      provider: "Telegram", log: "the chat in Telegram")
  end

  # Telegram's Bot API lists nothing a bot has sent, so there is nothing to
  # ask: a send's id comes only from a later post that quotes it
  # (TelegramBot#reveal_send), and until then a person must look.
  def self.find_dispatched(_dispatch)
    raise Dispatch::Unaskable, "Telegram lists nothing a bot has sent"
  end

  private
    # What the call answers for a message it tried: sent, with Telegram's id
    # for it, or not known yet, with the key it is closed under.
    def tried(dispatch, chat)
      raise Refusal, "This Telegram message to chat #{chat} was not sent." if dispatch.not_sent?
      return { sent: true, chat: chat, messageId: dispatch.provider_id.to_i } if dispatch.sent?
      { unknown: chat, key: dispatch.key, note: UNCONFIRMED }
    end

    # The same words to the same chat, just sent or perhaps sent: the agent
    # retrying a message that went, or may have, so it isn't sent twice.
    # Only a person ends an unknown one (Dispatch#close).
    def refuse_repeat(chat, fingerprint)
      earlier = agent.dispatches.repeated(fingerprint, by: invocation) or return
      at = Conversation.stamp(earlier.created_at, agent.time_zone)
      if earlier.sent?
        raise Refusal, "This same message went to chat #{chat} at #{at}#{" (Telegram id #{earlier.provider_id})" if earlier.provider_id}, " \
          "so it wasn't sent again."
      else
        raise Refusal, "This same message to chat #{chat}, sent at #{at}, may have gone and whether it did is still unknown " \
          "(key #{earlier.key}), so it wasn't sent again. Read telegram_messages for the chat, and ask your person to say on its card whether it went."
      end
    end
end
