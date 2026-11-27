require "net/http"

# An agent as a Campfire bot: Campfire's third channel (docs/campfire.md).
# The person makes the bot in Campfire and pastes its key here; Campfire posts
# each message that mentions the bot, or is sent to it directly, to this
# agent's webhook (CampfireWebhooksController), whose secret token is the only
# thing that admits it. The agent answers with campfire_say.
class CampfireBot < ApplicationRecord
  TIMEOUT = 10 # seconds
  PAGE = 40 # messages, as v1.5.8 lists them
  # Campfire's clock and ours may differ; a match is still this bot's own words.
  CLOCK_SLACK = 2.minutes
  # Failures after the post was sent: it may have arrived.
  MAY_HAVE_ARRIVED = [ Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE ].freeze
  # Failures before it was: it did not.
  UNREACHABLE = [ SocketError, SystemCallError, Net::OpenTimeout, OpenSSL::SSL::SSLError, IOError ].freeze

  # A post Campfire never answered and its room doesn't show: it may have arrived.
  class Unconfirmed < StandardError; end

  # Who asked a bot in a room, once answered there unnamed: gone (#258), dropped next.
  self.ignored_columns += %w[ askers ]

  belongs_to :agent
  broadcasts_refreshes_to :agent
  has_secure_token :token, length: 32
  encrypts :bot_key
  normalizes :bot_key, with: -> { it.strip }

  validates :bot_key, format: { with: /\A[1-9][0-9]*-[A-Za-z0-9]+\z/, message: "is the key Campfire shows for the bot, like 4-abc123" }

  # The install's Campfire; a workspace may have its own (Agent#campfire).
  def self.url = DurableAssistants::Campfire.url
  def self.configured? = url.present?

  # With an administrator to sign in as, the bot is made in the agent's
  # Campfire, named for it and pointed at its webhook; it joins every open room.
  def self.make_for(agent)
    bot = agent.build_campfire_bot(token: generate_unique_secure_token(length: 32))
    bot.bot_key = agent.campfire.admin.create_bot(name: agent.name, webhook_url: bot.webhook_url)
    bot.confirmed_at = Time.current
    bot.tap(&:save!)
  end

  # How rooms are used (config/skills/campfire-rooms.md) comes with the bot,
  # as its tools do. Once: a person may change or remove it after, and an
  # agent with no room for another skill goes without.
  ROOMS_SKILL = Rails.root.join("config/skills/campfire-rooms.md")
  after_create -> { agent.skills.from_markdown(ROOMS_SKILL.read).save unless agent.skills.exists?(name: "campfire-rooms") }

  # A key pasted again is vouched for again.
  before_save -> { self.confirmed_at = nil }, if: -> { will_save_change_to_bot_key? && !will_save_change_to_confirmed_at? }
  before_destroy :confirm_if_possible
  after_destroy_commit -> { CampfireBotRemovalJob.perform_later(agent.workspace, campfire_id) }, if: -> { campfire.admin? && confirmed_at }

  def campfire = agent.campfire

  # The administrator acts on a bot by the number at the front of its key, and
  # anyone can paste "7-x". So that number is trusted only once Campfire has
  # vouched for the whole key: this install made the bot, or the bots page
  # lists exactly this key. Otherwise one person could repoint, list or
  # remove another person's bot 7. A bot made before this check is vouched
  # for the first time the administrator acts on it.
  def confirmed_campfire_id
    confirm unless confirmed_at
    campfire_id
  end

  def campfire_id = DurableAssistants::Campfire.bot_id(bot_key)

  # A new webhook address; Campfire is told of it when this app can sign in.
  # False when Campfire must be told by hand.
  def renew_webhook
    regenerate_token
    campfire.admin? or return false
    campfire.admin.update_webhook(confirmed_campfire_id, name: agent.name, webhook_url: webhook_url)
    true
  end

  # The bot goes by its agent's name, which the relay routes on (@name): after
  # a rename Campfire is told the new one when this app can sign in, or the
  # person renames it there by hand. Campfire down never stops the rename.
  def rename
    campfire.admin? and campfire.admin.update_webhook(confirmed_campfire_id, name: agent.name, webhook_url: webhook_url)
  rescue DurableAssistants::Campfire::Error => error
    Rails.error.report(error, context: { agent_id: agent_id })
  end

  # Where Campfire posts to reach this agent: the office's Campfire reaches
  # the app inside the host too, past whatever sign-in stands in front of it;
  # another Campfire, a workspace's own among them, uses the app's address.
  def webhook_url
    base = (DurableAssistants.config(:app, :url) if agent.workspace.campfire_url) ||
      DurableAssistants.config(:campfire, :app_url).presence ||
      (DurableAssistants.kamal_url("web") unless DurableAssistants.config(:campfire, :url)) ||
      DurableAssistants.config(:app, :url)
    URI.join(base.to_s, Rails.application.routes.url_helpers.campfire_webhook_path(token)).to_s
  end

  # A message Campfire posted: its room is remembered, so the agent may answer
  # there without asking, and the text reaches the agent's thread as written
  # by someone else: from the agent's own person, by the name Campfire shows,
  # it steers; anyone else's waits in its inbox unless it can't wait (#85).
  def receive(payload)
    room, user, message = payload.values_at("room", "user", "message").map { it.is_a?(Hash) ? it : {} }
    text = message.dig("body", "plain").to_s
    return if room["id"].blank? || message["id"].blank? || text.blank?
    # Campfire takes the bot's own @name out of the text it posts; the HTML keeps that a mention was there.
    mentioned = message.dig("body", "html").to_s.include?(%(content-type="#{DurableAssistants::Campfire::MENTION}"))
    # A room post wakes the agent only if it @mentions it (Ajay, 18 Nov, #258);
    # any other stays in the room, for campfire_history. A direct room, which
    # Campfire gives no name, is the person writing to the agent.
    return unless mentioned || room["name"].blank?

    hear(room["id"], room["name"])
    agent.workspace.campfire_rooms.find_or_create_by!(room_id: room["id"].to_i).person_wrote!
    agent.conversation.receive(text, from: "#{user["name"].presence || "someone"} in #{room["name"].presence || "a room"}", via: "Campfire",
      answer: "#{"It @mentions you; Campfire leaves your own name out of the text. " if mentioned}" \
        "To answer, use campfire_say with room #{room["id"]}; ending your turn does not answer.",
      sent_at: (Time.iso8601(message["created_at"].to_s) rescue nil), request_id: "campfire:#{agent_id}:#{message["id"]}",
      from_person: agent.user.goes_by?(user["name"]))
  end

  def heard_in?(room) = rooms.key?(room.to_s)

  # What this bot posted, passed on to each other agent of its workspace that
  # it names ("@Jordan Reyes") and that is a bot too: Campfire posts a bot's
  # words to no other bot. An agent of another workspace, even one of the same
  # name or made by the same person, hears nothing (docs/design/workspaces.md, 2.1). The room is theirs to answer in, as if it had written to
  # them; it waits in their inbox, as anyone else's words do, unless it can't
  # wait (#85). Only a name passes it on: an answer that doesn't name the agent
  # that asked stays in the room (#258). Returns who had it, and who didn't
  # while the room is held (Workspace::CampfireRoom).
  def relay(room, text, key:)
    others = agent.workspace.agents.where.not(id: agent_id).includes(:campfire_bot).select(&:campfire_bot)
    named = others.select { names?(text, it) }
    return {} if named.empty?

    room_name = rooms[room.to_s].presence || "a room"
    unless agent.workspace.campfire_rooms.find_or_create_by!(room_id: Integer(room)).relay!(room_name)
      return { not_passed_on: named.map(&:name),
               why: "Agents passed #{Workspace::CampfireRoom::SPINNING} messages in a minute in this room, so it is paused until one of your people writes to one of you." }
    end

    named.each do |other|
      via_app = "#{agent.name} is another agent; this came through the app, since Campfire passes no agent's words to another. "
      # Named in a closed room its bot isn't in: offering the room would only
      # end in Campfire's refusal, so it isn't marked heard and isn't offered.
      answer = if other.campfire_bot.member_of?(room) == false
        via_app + "Your bot isn't in #{room_name} (Campfire room #{room}), so you can't post there: " \
          "answer your person another way, or ask them to add your bot to the room."
      else
        other.campfire_bot.hear(room, room_name)
        via_app + "To answer, use campfire_say with room #{room}, naming @#{agent.name} so it reaches them. Ending your turn does not answer."
      end
      other.conversation.receive(text, from: "#{agent.name} in #{room_name}", via: "Campfire", answer: answer,
        request_id: "campfire:#{other.id}:#{key}")
    end
    { passed_on: named.map(&:name) }
  end

  # Whether Campfire has this bot in the room, from the administrator's bots
  # page; nil where this install can't sign in to ask, or the page can't be read.
  def member_of?(room)
    return unless campfire.admin?
    campfire.admin.rooms_of(confirmed_campfire_id).key?(Integer(room))
  rescue DurableAssistants::Campfire::Error
    nil
  end

  def hear(room, name)
    with_lock { update!(rooms: rooms.merge(room.to_s => name.to_s.truncate(100))) }
  end

  def forget(room)
    with_lock { update!(rooms: rooms.except(room.to_s)) } if rooms.key?(room.to_s)
  end

  # "@Name", not followed by more of a word: "@Jordan" names neither "Jordan Reyes" nor "Jordanka".
  def names?(text, other) = text.match?(/(?<![\w@])@#{Regexp.escape(other.name)}(?![\w])/i)

  # Deleting the bot deactivates it in Campfire only if its key is vouched
  # for; a bot Campfire can't vouch for is left there, for a person to remove.
  def confirm_if_possible
    confirm if campfire.admin? && !confirmed_at
  rescue DurableAssistants::Campfire::Error => error
    Rails.logger.info "Campfire bot #{id} not vouched for, so left in Campfire: #{error.message}"
  end

  def confirm
    campfire.admin.lists_key?(bot_key) or raise DurableAssistants::Campfire::Error,
      "Campfire's bots page doesn't show this bot's key, so it can't be changed from here. Check the key on the agent's Channels page, or do it by hand in Campfire."
    update!(confirmed_at: Time.current)
  end

  # Posts as the bot. Campfire takes the message as the request's body, and
  # says where the new message is: its id. A post whose answer never came
  # may have arrived; it is looked for in the room (#posted_id), and raises
  # Unconfirmed if it isn't there.
  def say(room, text)
    started = Time.current
    uri = messages_uri(room)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.post(uri.request_uri, text, "Content-Type" => "text/plain; charset=utf-8")
    end
    return response["location"].to_s[%r{/messages/(\d+)\z}, 1]&.to_i if response.is_a?(Net::HTTPSuccess)
    if response.is_a?(Net::HTTPNotFound)
      # Campfire answers a bot outside a room as if the room weren't there.
      # Forgotten, so a later post there asks the person first.
      forget(room)
      raise Tool::Refusal, "Your bot isn't a member of Campfire room #{Integer(room)}, a closed room, so it can't post there. " \
        "Ask the person who runs Campfire to add it, or answer another way."
    end
    raise Tool::Refusal, "Campfire refused the message (#{response.code})."
  rescue *MAY_HAVE_ARRIVED
    posted_id(room, text, since: started) or raise Unconfirmed
  rescue *UNREACHABLE => problem
    raise Tool::Refusal, "Could not reach Campfire (#{problem.class.name.demodulize})."
  end

  # The room's last messages, up to Campfire's page of 40, oldest first, as
  # the bot may read them (v1.5.8's bot API, only in rooms it is in).
  def history(room, limit: PAGE)
    uri = messages_uri(room)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri.request_uri, "Accept" => "application/json")
    end
    raise Tool::Refusal, "Your bot isn't a member of Campfire room #{Integer(room)}, so it can't read it." if response.is_a?(Net::HTTPNotFound)
    raise Tool::Refusal, "Campfire refused to list the room (#{response.code})." unless response.is_a?(Net::HTTPSuccess)
    listed = JSON.parse(response.body.to_s) rescue nil
    raise Tool::Refusal, "Campfire's list of the room isn't as #{DurableAssistants::Campfire::PINNED} had it." unless listed.is_a?(Array) && listed.all?(Hash)
    listed.last(limit).map do |message|
      { id: message["id"], author: message.dig("creator", "name"), author_id: message.dig("creator", "id"),
        at: message["created_at"], text: message.dig("body", "plain_text") }
    end
  rescue *MAY_HAVE_ARRIVED, *UNREACHABLE => problem
    raise Tool::Refusal, "Could not reach Campfire (#{problem.class.name.demodulize})."
  end

  private
    def messages_uri(room) = URI.join(campfire.url, "/rooms/#{Integer(room)}/#{bot_key}/messages")

    # Campfire takes no client message id from a bot, so its own post is the
    # newest by this bot with the same words since the post began.
    def posted_id(room, text, since:)
      history(room).reverse.find do |message|
        at = Time.iso8601(message[:at].to_s) rescue nil
        message[:author_id] == campfire_id && message[:text].to_s.squish == text.squish && at&.after?(since - CLOCK_SLACK)
      end&.dig(:id)
    rescue Tool::Refusal
      nil
    end
end
