class Conversation < ApplicationRecord
  include ActionView::RecordIdentifier

  # The sidecar's store and this database disagree about which conversation a
  # request made (one restored without the other). Never guess.
  class Mismatch < StandardError; end

  STATUSES = %w[ idle running waiting error ].freeze
  BUSY_MODES = %w[ followUp steer ].freeze
  PAGE = 200
  SIDECAR_STATUSES = { "idle" => "idle", "done" => "idle", "cancelled" => "idle", "running" => "running",
                       "waiting" => "waiting", "error" => "error", "blocked" => "error" }.freeze
  IMAGES_PER_MESSAGE = 4
  IMAGE_TYPES = { "image/jpeg" => "jpg", "image/png" => "png", "image/webp" => "webp", "image/gif" => "gif" }.freeze

  belongs_to :user
  belongs_to :bot
  has_many :invocations, dependent: :destroy
  has_many :messages, dependent: :delete_all

  validates :request_id, :durable_id, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :bot_belongs_to_user

  def access = Agent::Access.for(bot)

  # Sends the bot's current definition with every message: an edit to the
  # bot applies from the next message, which is what a person editing a
  # persona wants.
  def submit(content, request_id:, when_busy: "followUp")
    definition = bot.definition
    client.submit(access, durable_id, request_id: request_id, content: content, when_busy: when_busy, definition: definition)
    update!(definition_digest: definition[:digest], title: title.presence || content.squish.truncate(60))
    broadcast_title if saved_change_to_title?
    mark("running")
    # The person's message is committed now (or queued behind a running
    # reply): put it on the page without waiting for a ping.
    pull
  end

  def cancel(request_id:)
    client.cancel(access, durable_id, request_id)
  end

  # A doorbell: it carries no decision. The sidecar re-sends the waiting call
  # and the ledger answers from what Rails recorded.
  def wake(invocation)
    client.wake(access, durable_id, invocation.wait_key)
  end

  # Pulls the entries the sidecar committed since the last pull. A missed
  # ping heals at the next pull or page load: the cursor, not the ping, says
  # what is new, and each entry is recorded once.
  def sync!
    loop do
      page = client.entries(access, durable_id, after: last_entry_id, limit: PAGE)
      transaction do
        Array(page["entries"]).each { record_entry(it) }
        update!(last_entry_id: page["cursor"]) if page["cursor"].is_a?(Integer)
      end
      break unless page["more"] == true
    end
  end

  # The copy is a projection: drop it and pull it again.
  def resync!
    transaction do
      messages.destroy_all
      update!(last_entry_id: nil)
    end
    sync!
  end

  # Where the sidecar says the conversation stands, for a page load: the
  # frame that said "done" may never have arrived.
  def refresh_status!
    state = client.snapshot(access, durable_id)
    failure = state.dig("failure", "reason")
    update!(failure: failure) if %w[ error blocked ].include?(state["status"])
    update!(usage: Usage.from(state["usage"])) if state["usage"]
    mark(SIDECAR_STATUSES.fetch(state["status"], status))
    clear_live unless busy?
  end

  # Pulls now, in this request. A pull that fails is left to a job, which
  # retries it; says whether this one succeeded.
  def pull
    sync!
    true
  rescue DurableAssistants::PiDurable::Client::Error
    ConversationSyncJob.perform_later(self)
    false
  end

  # Empties the live reply once its message is on the page; "Working…" while
  # more is coming. Its sequence is above any frame sent before it, so a frame
  # arriving late cannot bring the old tail back.
  def clear_live(after: 0, working: false)
    broadcast_replace_to self, target: dom_id(self, :live), partial: "conversations/live",
      locals: { conversation: self, seq: [ after + 1, (Time.current.to_f * 1000).to_i ].max, working: working }
  end

  # A frame from the sidecar: the whole live reply so far, and what each
  # running tool has printed, morphed into the page so only what changed
  # moves; an older frame (lower seq) is dropped there. The last frame
  # (busy: false) carries no reply: the reply is a committed message by then,
  # so it is pulled onto the page first and only then the live tail clears and
  # the status settles. Nothing blinks out. It carries the conversation's
  # totals instead. Live output is never stored: the committed result
  # replaces it.
  def receive_frame(seq:, busy:, tail:, failure:, thinking: "", tools: [], usage: nil)
    update!(failure: busy ? nil : failure.presence)
    if busy
      mark(invocations.awaiting_person.exists? ? "waiting" : "running")
      broadcast_replace_to self, target: dom_id(self, :live), partial: "conversations/live", attributes: { method: :morph },
        locals: { conversation: self, seq: seq, tail: tail.to_s, thinking: thinking.to_s, working: true }
      tools.each { broadcast_tool_output(it, seq) }
    else
      pulled = pull
      mark(failure.present? ? "error" : "idle")
      clear_live(after: seq) if pulled
      record_usage(usage) if usage
    end
  end

  def mark(new_status)
    return if status == new_status
    update!(status: new_status)
    broadcast_replace_to self, target: dom_id(self, :status), partial: "conversations/status", locals: { conversation: self }
  end

  def busy? = status.in?(%w[ running waiting ])
  def waiting? = status == "waiting"

  def to_s = title.presence || "New conversation"

  private
    def client = DurableAssistants::PiDurable::Client.new

    # The title in the header and in the sidebar's list.
    def broadcast_title
      %i[ title nav_title ].each { broadcast_update_to self, target: dom_id(self, it), html: ERB::Util.html_escape(title) }
    end

    # The bot's own tools show their ledger row, which says all there is; a
    # sidecar tool (the computer's shell, a browser) shows what it printed.
    # A script's call has no element of its own until it prints, so its line
    # is appended to the script's list, over the one already there.
    def broadcast_tool_output(tool, seq)
      return if bot.tool(tool["name"])
      call_id = tool["callId"]
      if (script = Invocation.script_call_id(call_id))
        Turbo::StreamsChannel.broadcast_append_to self, target: "#{Invocation.dom_target(script)}_calls", partial: "messages/live_tool_call",
          locals: { tool: tool, seq: seq }
      else
        Turbo::StreamsChannel.broadcast_replace_to self, target: "#{Invocation.dom_target(call_id)}_output", partial: "messages/tool_output",
          attributes: { method: :morph }, locals: { call_id: call_id, output: tool["output"].to_s, seq: seq }
      end
    end

    def record_usage(raw)
      update!(usage: Usage.from(raw))
      broadcast_replace_to self, target: dom_id(self, :usage), partial: "conversations/usage", locals: { conversation: self }
    end

    def record_entry(entry)
      return unless entry.is_a?(Hash) && entry["id"].present? && entry["entryId"].is_a?(Integer)
      messages.create_or_find_by!(entry_key: entry["id"].to_s) do |message|
        message.entry_id = entry["entryId"]
        message.role = entry["role"].to_s
        message.content = entry["content"].to_s
        message.tool_name = entry["toolName"]
        message.tool_call_id = entry["toolCallId"]
        message.tool_calls = Array(entry["toolCalls"]).map { it.slice("id", "name", "arguments") }
        message.error = entry["isError"] == true
        message.thinking = entry["thinking"].presence
        message.usage = Usage.from(entry["usage"])
        Array(entry["images"]).first(IMAGES_PER_MESSAGE).each_with_index { |image, index| attach_image(message, image, index) }
      end
    end

    def attach_image(message, image, index)
      type = image["mimeType"] if image.is_a?(Hash)
      return unless IMAGE_TYPES.key?(type) && image["data"].is_a?(String)
      bytes = Base64.strict_decode64(image["data"])
      return if bytes.bytesize > 5.megabytes
      message.images.attach(io: StringIO.new(bytes), filename: "image-#{message.entry_key}-#{index}.#{IMAGE_TYPES[type]}", content_type: type)
    rescue ArgumentError
      nil
    end

    def bot_belongs_to_user
      errors.add(:bot, "belongs to someone else") if bot && user && bot.user_id != user_id
    end
end
