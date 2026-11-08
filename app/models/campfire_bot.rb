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

  def self.url = DurableAssistants.config(:campfire, :url).presence
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

  # Where Campfire posts to reach this agent.
  def webhook_url
    base = DurableAssistants.config(:campfire, :app_url).presence || DurableAssistants.config(:app, :url)
    URI.join(base.to_s, Rails.application.routes.url_helpers.campfire_webhook_path(token)).to_s
  end

  # A message Campfire posted: its room is remembered, so the agent may answer
  # there without asking, and the text reaches the agent's thread as written
  # by someone else.
  def receive(payload)
    room, user, message = payload.values_at("room", "user", "message").map { it.is_a?(Hash) ? it : {} }
    text = message.dig("body", "plain").to_s
    return if room["id"].blank? || message["id"].blank? || text.blank?

    with_lock { update!(rooms: rooms.merge(room["id"].to_s => room["name"].to_s.truncate(100))) }
    agent.conversation.receive(text, from: "#{user["name"].presence || "someone"} in #{room["name"].presence || "a room"}", via: "Campfire",
      answer: "To answer, use campfire_say with room #{room["id"]}; ending your turn does not answer.",
      request_id: "campfire:#{agent_id}:#{message["id"]}")
  end

  def heard_in?(room) = rooms.key?(room.to_s)

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
