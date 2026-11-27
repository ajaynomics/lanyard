# An agent as a Telegram bot (docs/telegram.md). The workspace's owner makes
# the bot with Telegram's BotFather and saves its token in the vault, shared
# with the agent; here goes only the entry's name. The token is read from the
# vault for each call to Telegram and dropped after it, as a mail account's
# password is (Agent::MailAccount), so it is never in the database, a log or
# a command's arguments, and the agent never sees it.
#
# Telegram posts each message to the bot (in a group it is in, or written to
# it directly) to this bot's webhook (TelegramWebhooksController), with the
# secret it was given in a header; the words reach the agent's thread as
# someone else's, as mail and Campfire's do. The agent answers with
# telegram_send, which its person approves every time.
class TelegramBot < ApplicationRecord
  # The vault entry is missing, isn't a bot token or is saved for another
  # address; in words a person or a model can read, never with the token.
  class SignInError < StandardError; end

  # Kept for each chat the bot heard from, so a card can name it.
  CHAT_NAME = 100

  belongs_to :agent
  has_many :messages, class_name: "TelegramMessage"
  broadcasts_refreshes_to :agent
  has_secure_token :webhook_secret, length: 32
  encrypts :webhook_secret

  normalizes :vault_entry, with: -> { it.squish.presence }
  validates :vault_entry, presence: true, length: { maximum: 200 }

  # Usable only where the agent can read the vault.
  def usable? = DurableAssistants::Passbolt.configured?(agent)

  # Checks the token with Telegram and tells it where to post, with a new
  # secret it must send back, so a bot whose token was replaced is turned
  # away. Kept only if Telegram took both; a new one needs its id first, for
  # the address, and goes again if Telegram refuses.
  def connect
    return false unless valid?
    fresh = new_record?
    save! if fresh
    secret = self.class.generate_unique_secure_token(length: 32)
    found = token
    me = DurableAssistants::Telegram.me(found)
    DurableAssistants::Telegram.set_webhook(found, url: webhook_url, secret: secret)
    update!(username: me["username"], webhook_secret: secret)
  rescue SignInError, DurableAssistants::Telegram::Error => error
    destroy! if fresh
    errors.add(:base, error.message)
    false
  end

  # Telegram stops posting; best effort, as the bot goes either way.
  def disconnect
    DurableAssistants::Telegram.delete_webhook(token)
    true
  rescue SignInError, DurableAssistants::Telegram::Error, DurableAssistants::Passbolt::Error => error
    Rails.logger.info "Telegram bot #{id} not told to stop posting: #{error.class.name}"
    false
  end

  # Where Telegram posts: the app's own address, which faces the internet.
  def webhook_url
    URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.telegram_webhook_path(self)).to_s
  end

  def secret?(given) = given.is_a?(String) && webhook_secret.present? && ActiveSupport::SecurityUtils.secure_compare(given, webhook_secret)

  # One update Telegram posted. Its chat is remembered and the post kept
  # (TelegramMessage). Its words and its files' names reach the agent's thread
  # as someone else's when it calls on the bot: a direct message always, a
  # group's post only when it mentions or answers the bot, so a group's talk
  # among people starts no turn (#189). A message with neither words nor
  # files (someone joined, a title changed) says nothing to the agent.
  def receive(update)
    message = update["message"]
    return unless message.is_a?(Hash) && message["chat"].is_a?(Hash) && message.dig("chat", "id").present? &&
      Integer(message["message_id"], exception: false)
    received = Update.new(message)
    return if received.empty?

    hear(received.chat_id, received.chat_label)
    messages.keep(received)
    reveal_send(received.chat_id, message["reply_to_message"])
    return unless received.to?(username)

    agent.conversation.receive(received.text, from: "#{received.sender} in #{received.chat_name}", via: "Telegram",
      answer: "To answer, use telegram_send with chat #{received.chat_id}; ending your turn does not answer.",
      sent_at: received.sent_at, request_id: "telegram:#{agent_id}:#{update["update_id"] || "#{received.chat_id}-#{message["message_id"]}"}",
      # Alone or in a group, the agent's own person, by the name Telegram
      # shows, steers; anyone else waits in its inbox unless it can't wait (#85).
      opening: received.words, from_person: agent.user.goes_by?(received.sender))
  end

  def heard_in?(chat) = chats.key?(chat.to_s)

  def chat_name(chat) = chats[chat.to_s]

  # The chat an id or a title stands for, among those it heard from; nil for
  # any other, or for a title two of its chats share.
  def chat_named(name)
    name = name.to_s.squish
    return Integer(name) if name.match?(/\A-?\d+\z/) && heard_in?(name)
    chats.select { |_, title| title.casecmp?(name) }.keys.then { Integer(it.sole) if it.one? }
  end

  # What a chat said and what the bot posted there, newest first, narrowed
  # the same way (Tool::TelegramMessages). The posts it heard are its own
  # record (TelegramMessage); its own posts come from the send ledger, since
  # Telegram never echoes a bot its own messages. One whose answer never came
  # is shown as unknown, so the agent can see whether it arrived before
  # sending anything again (#249).
  def posts(chat: nil, query: nil, since: nil, before: nil, limit:)
    heard = messages.in_chat(chat).saying(query).sent_between(since, before).newest_first.limit(limit)
    mine = Tool::TelegramSend.sent_to(agent, chat, saying: query, between: (since..before if since || before)).last(limit)
    # Each list is newest first already; the newest of both together is what it asked for.
    (heard.map { [ it.sent_at, it.listed(chat_name(it.chat_id), agent.time_zone) ] } + mine.map { [ it.created_at, listed_send(it) ] })
      .max_by(limit) { it.first }.map { it.last }
  end

  # Posts as the bot; Telegram's id for the message.
  def say(chat, text) = DurableAssistants::Telegram.send_message(token, chat: Integer(chat), text: text)

  # What getFile says of a file the bot was sent.
  def file_info(id)
    found = DurableAssistants::Telegram.file(token, id)
    name = found["file_path"].to_s.split("/").last.presence || "file"
    { name: DurableAssistants::Google.safe_name(name), type: Marcel::MimeType.for(name: name), size: found["file_size"].to_i }
  end

  def download(id)
    path = DurableAssistants::Telegram.file(token, id)["file_path"]
    DurableAssistants::Telegram.download(token, path)
  end

  def inspect = "#<#{self.class.name} #{id} @#{username} from #{vault_entry}>"

  private
    def hear(chat, name)
      with_lock { update!(chats: chats.merge(chat.to_s => name.to_s.truncate(CHAT_NAME))) } unless chats[chat.to_s] == name
    end

    # A send of the bot's own, as a post it heard is listed
    # (TelegramMessage#listed), and marked as its own. One Telegram never
    # answered has no id to give, and says whether it went is unknown.
    def listed_send(dispatch)
      chat = Integer(dispatch.invocation.call_arguments["chat"])
      { id: dispatch.provider_id&.to_i, chat: { id: chat, name: chat_name(chat) }, from: agent.name,
        at: dispatch.created_at.in_time_zone(agent.time_zone).iso8601, text: dispatch.invocation.call_arguments["text"],
        yours: true, unknown: (true unless dispatch.sent?) }.compact
    end

    # A post of the bot's own, as a reply quotes the message it answers,
    # whole and with Telegram's id for it. Telegram tells a bot nothing of
    # its own posts, so a send whose answer never came has no id until
    # something like this shows one. Matched conservatively: the same chat
    # and the same words, and only against a send still waiting, so the
    # oldest such send is the one confirmed and no other post ever is.
    def reveal_send(chat, quoted)
      return unless username.present? && quoted.is_a?(Hash) && quoted.dig("from", "is_bot") == true &&
        quoted.dig("from", "username").to_s.casecmp?(username) && quoted["text"].present? &&
        Integer(quoted["message_id"], exception: false)
      agent.dispatches.waiting.where(fingerprint: Tool::TelegramSend.fingerprint(self, chat, quoted["text"]))
        .order(:created_at).first&.revealed(quoted["message_id"])
    end

    # Read from the vault for this one call. The entry must be saved for
    # Telegram's API, as a mail account's is for its server: a password
    # shared with the agent for another site never goes to Telegram.
    def token
      entry = DurableAssistants::Passbolt.sign_in_by_name(agent, vault_entry)
      raise SignInError, "#{vault_entry} is saved for #{entry.host || "no address"}, not #{DurableAssistants::Telegram::HOST}, so it is not sent there." unless
        entry.host == DurableAssistants::Telegram::HOST
      raise SignInError, "#{vault_entry} has no Telegram bot token as its password." unless DurableAssistants::Telegram.token?(entry.password)
      entry.password
    rescue DurableAssistants::Passbolt::Error => error
      raise SignInError, error.message
    end
end
