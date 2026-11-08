require "net/http"

# An agent as a Campfire bot: Campfire's third channel (docs/campfire.md).
# The person makes the bot in Campfire and pastes its key here; Campfire posts
# each message that mentions the bot, or is sent to it directly, to this
# agent's webhook (CampfireWebhooksController), whose secret token is the only
# thing that admits it. The agent answers with campfire_say.
class CampfireBot < ApplicationRecord
  TIMEOUT = 10 # seconds

  belongs_to :agent
  has_secure_token :token, length: 32
  encrypts :bot_key
  normalizes :bot_key, with: -> { it.strip }

  validates :bot_key, format: { with: /\A\d+-[A-Za-z0-9]+\z/, message: "is the key Campfire shows for the bot, like 4-abc123" }

  def self.url = DurableAssistants::Campfire.url
  def self.configured? = url.present?

  # With an administrator to sign in as, the bot is made in Campfire, named
  # for the agent and pointed at its webhook; it joins every open room.
  def self.make_for(agent)
    bot = agent.build_campfire_bot(token: generate_unique_secure_token(length: 32))
    bot.bot_key = DurableAssistants::Campfire.admin.create_bot(name: agent.name, webhook_url: bot.webhook_url)
    bot.tap(&:save!)
  end

  after_destroy_commit -> { CampfireBotRemovalJob.perform_later(agent.user, campfire_id) }, if: -> { DurableAssistants::Campfire.admin? }

  def campfire_id = DurableAssistants::Campfire.bot_id(bot_key)

  # A new webhook address; Campfire is told of it when this app can sign in.
  # False when Campfire must be told by hand.
  def renew_webhook
    regenerate_token
    DurableAssistants::Campfire.admin? or return false
    DurableAssistants::Campfire.admin.update_webhook(campfire_id, name: agent.name, webhook_url: webhook_url)
    true
  end

  # Where Campfire posts to reach this agent: the office's Campfire reaches
  # the app inside the host too, past whatever sign-in stands in front of it;
  # another Campfire uses the app's address.
  def webhook_url
    base = DurableAssistants.config(:campfire, :app_url).presence ||
      (DurableAssistants.kamal_url("web") unless DurableAssistants.config(:campfire, :url)) ||
      DurableAssistants.config(:app, :url)
    URI.join(base.to_s, Rails.application.routes.url_helpers.campfire_webhook_path(token)).to_s
  end

  # A message Campfire posted: its room is remembered, so the agent may answer
  # there without asking, and the text reaches the agent's thread as written
  # by someone else.
  def receive(payload)
    room, user, message = payload.values_at("room", "user", "message").map { it.is_a?(Hash) ? it : {} }
    text = message.dig("body", "plain").to_s
    return if room["id"].blank? || message["id"].blank? || text.blank?

    hear(room["id"], room["name"])
    answered_person(room["id"])
    agent.user.campfire_rooms.find_or_create_by!(room_id: room["id"].to_i).person_wrote!
    # Campfire takes the bot's own @name out of the text it posts; the HTML keeps that a mention was there.
    mentioned = message.dig("body", "html").to_s.include?(%(content-type="#{DurableAssistants::Campfire::MENTION}"))
    agent.conversation.receive(text, from: "#{user["name"].presence || "someone"} in #{room["name"].presence || "a room"}", via: "Campfire",
      answer: "#{"It @mentions you; Campfire leaves your own name out of the text. " if mentioned}" \
        "To answer, use campfire_say with room #{room["id"]}; ending your turn does not answer.",
      request_id: "campfire:#{agent_id}:#{message["id"]}")
  end

  def heard_in?(room) = rooms.key?(room.to_s)

  # What this bot posted, passed on to each other agent of the person's that it
  # names ("@Jordan Reyes") and that is a bot too: Campfire posts a bot's words
  # to no other bot. The room is theirs to answer in, as if it had written to
  # them. An agent that asked this one in the room (asker) has its answers
  # there too, named or not: an answer without "@Durable Assistants" would
  # otherwise never reach Avery. Returns who had it, and who didn't while the
  # room is held (CampfireRoom).
  def relay(room, text, key:)
    others = agent.user.agents.where.not(id: agent_id).includes(:campfire_bot).select(&:campfire_bot)
    named = others.select { names?(text, it) || it.id == askers[room.to_s] }
    return {} if named.empty?

    room_name = rooms[room.to_s].presence || "a room"
    unless agent.user.campfire_rooms.find_or_create_by!(room_id: Integer(room)).relay!(room_name)
      return { not_passed_on: named.map(&:name),
               why: "Agents passed #{CampfireRoom::SPINNING} messages in a minute in this room, so it is paused until your person writes to one of you." }
    end

    named.each do |other|
      other.campfire_bot.hear(room, room_name)
      other.campfire_bot.asked_by(room, agent)
      other.conversation.receive(text, from: "#{agent.name} in #{room_name}", via: "Campfire",
        answer: "#{agent.name} is another agent; this came through the app, since Campfire passes no agent's words to another. " \
          "To answer, use campfire_say with room #{room}; what you post there reaches #{agent.name}. Ending your turn does not answer.",
        request_id: "campfire:#{other.id}:#{key}")
    end
    { passed_on: named.map(&:name) }
  end

  # The agent whose words the app last passed to this one in the room.
  def asked_by(room, other)
    with_lock { update!(askers: askers.merge(room.to_s => other.id)) }
  end

  # A person wrote to this bot there: what it posts next answers them.
  def answered_person(room)
    with_lock { update!(askers: askers.except(room.to_s)) } if askers.key?(room.to_s)
  end

  def hear(room, name)
    with_lock { update!(rooms: rooms.merge(room.to_s => name.to_s.truncate(100))) }
  end

  # "@Name", not followed by more of a word: "@Jordan" names neither "Jordan Reyes" nor "Jordanka".
  def names?(text, other) = text.match?(/(?<![\w@])@#{Regexp.escape(other.name)}(?![\w])/i)

  # Posts as the bot. Campfire takes the message as the request's body.
  def say(room, text)
    uri = URI.join(self.class.url, "/rooms/#{Integer(room)}/#{bot_key}/messages")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.post(uri.request_uri, text, "Content-Type" => "text/plain; charset=utf-8")
    end
    response.is_a?(Net::HTTPSuccess) or raise Tool::Refusal, "Campfire refused the message (#{response.code})."
  rescue *[ SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, IOError ] => problem
    raise Tool::Refusal, "Could not reach Campfire (#{problem.class.name.demodulize})."
  end
end
