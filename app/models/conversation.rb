class Conversation < ApplicationRecord
  include ActionView::RecordIdentifier

  # The sidecar's store and this database disagree about which conversation a
  # request made (one restored without the other). Never guess.
  class Mismatch < StandardError; end
  # Pictures that cannot go with a message; the message says why, for the person.
  class ImagesRefused < StandardError; end

  STATUSES = %w[ idle running waiting error ].freeze
  BUSY_MODES = %w[ followUp steer ].freeze
  PAGE = 200
  SIDECAR_STATUSES = { "idle" => "idle", "done" => "idle", "cancelled" => "idle", "running" => "running",
                       "waiting" => "waiting", "error" => "error", "blocked" => "error" }.freeze
  IMAGES_PER_MESSAGE = 4
  IMAGE_TYPES = { "image/jpeg" => "jpg", "image/png" => "png", "image/webp" => "webp", "image/gif" => "gif" }.freeze
  IMAGE_BYTES = 5.megabytes
  # What a person may say about what a summary should keep; the sidecar holds the same limit.
  COMPACTION_INSTRUCTIONS = 4_096

  include Archivable, Listable

  belongs_to :user
  belongs_to :bot
  # A branch knows the conversation it came from; the parent does not change.
  belongs_to :parent, class_name: "Conversation", optional: true, counter_cache: :branches_count
  # The top of the family, so the whole family is one where (family_of). Nil
  # on the top conversation itself; only branch writes it.
  belongs_to :root, class_name: "Conversation", optional: true
  has_many :branches, class_name: "Conversation", foreign_key: :parent_id, inverse_of: :parent, dependent: :nullify
  has_many :invocations, dependent: :destroy
  has_many :messages, dependent: :delete_all
  # The agent's own connectors, pi's project .pi/mcp.json.
  has_many :mcp_servers, -> { order(:name) }, dependent: :destroy

  scope :family_of, ->(conversation) {
    top = conversation.root_id || conversation.id
    where(id: top).or(where(root_id: top))
  }

  # A conversation with no messages yet sorts by when it began.
  before_create { self.last_message_at ||= Time.current }

  validates :request_id, :durable_id, presence: true
  validates :title, length: { maximum: 200 }
  validates :status, inclusion: { in: STATUSES }
  validate :bot_belongs_to_user, :parent_is_the_same_bots

  # The header and the sidebar follow a new title, however it was set.
  after_update_commit :broadcast_title, if: :saved_change_to_title?

  def access = Agent::Access.for(bot)

  # The connectors this agent uses, as pi reads its two mcp.json files: the
  # person's own, with this agent's entry replacing one of the same name, and
  # an entry that is switched off removing it. Read afresh for every message
  # (Bot#definition), so a change applies from the agent's next turn. A
  # command connector needs the agent's computer, so without one it is left out.
  def connectors
    own = mcp_servers.scope.to_a
    (own + user.mcp_servers.global.reject { |global| own.any? { it.name == global.name } })
      .select { it.enabled? && it.usable_by?(self) }.sort_by(&:name)
  end

  def tools = bot.tools(connectors)

  def tool(name) = tools.find { it.tool_name == name }

  # Sends the bot's current definition with every message: an edit to the
  # bot applies from the next message, which is what a person editing a
  # persona wants.
  #
  # Pictures go as content blocks and are not stored here: the person's
  # message is pulled back from the committed entry, and record_entry attaches
  # its pictures then, as it does a tool's screenshot.
  #
  # A saved prompt or a skill is expanded here (Bot#expand), so it works the
  # same with or without JavaScript; the title keeps what the person typed.
  def submit(content, request_id:, when_busy: "followUp", images: [])
    definition = bot.definition(tools)
    begin
      client.submit(access, durable_id, request_id: request_id, content: content_blocks(bot.expand(content), images), when_busy: when_busy, definition: definition)
    rescue DurableAssistants::PiDurable::Client::Error => error
      raise ImagesRefused, "#{bot}'s model can't look at pictures. Send words only, or choose another model in the bot's settings." if error.category == "images_unsupported"
      raise
    end
    update!(definition_digest: definition[:digest], title: title.presence || content.squish.truncate(60).presence || "Picture")
    mark("running")
    # The person's message is committed now (or queued behind a running
    # reply): put it on the page without waiting for a ping.
    pull
  end

  # A new conversation for the same person and bot that starts as a copy of
  # this one up to and including entry `after`, and goes on on its own. With
  # no entry (editing the first message), it starts empty. Repeatable by
  # request id, on both sides, like start_conversation. Its messages arrive
  # with the first pull, which brings the copied history.
  def branch(request_id:, after: nil)
    reply = after ? client.fork(access, durable_id, request_id: request_id, at: after) : client.conversation(access, request_id)
    durable = reply.fetch("id").to_s
    branch = bot.conversations.create_or_find_by!(request_id: request_id) do
      it.user = user
      it.durable_id = durable
      it.parent = self
      it.root = root || self
      it.forked_at_entry_id = after
      it.title = "#{to_s.delete_suffix(' (branch)')} (branch)"
    end
    raise Mismatch unless branch.durable_id == durable && branch.parent_id == id
    branch
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
    raise Mismatch
  end

  # How many branches were taken after each entry, for the markers under a
  # transcript's messages: one query for the page.
  def branch_counts
    @branch_counts ||= branches.group(:forked_at_entry_id).count
  end

  def tree = Tree.new(self)

  def cancel(request_id:)
    client.cancel(access, durable_id, request_id)
  end

  # Summarises the earlier messages now rather than at the threshold. The
  # sidecar makes the summary while the conversation goes on; frames say so,
  # and the summary arrives as a message.
  def compact(request_id:, instructions: nil)
    client.compact(access, durable_id, request_id: request_id, instructions: instructions)
  end

  # The whole history as pi's session file, passed to the block in chunks as
  # the sidecar writes it: built from the sidecar's store, which holds what
  # the messages here leave out.
  def export(&chunks)
    client.export(access, durable_id, title: to_s, &chunks)
  end

  # Whether the agent has a screen to open: its computer is a Sprite that is on.
  def screen?
    computer = bot.computer
    computer.present? && computer.on? && computer.sprites?
  end

  # A websocket to the agent's screen, through the sidecar, which wakes the
  # Sprite first. Yields the open connection.
  def screen(&block)
    client.screen(access, durable_id, computer: bot.computer.name, &block)
  end

  # Whether a summary is being made, or the newest one failed, as the sidecar
  # said on this page load; frames keep the page current after that.
  def compacting? = @compacting == true
  def compaction_failed? = @compaction_failed == true

  # What the model saw at its newest reply, for the context meter: nil before
  # any reply, and once a summary has replaced what that reply measured.
  def context_tokens
    marker = context_marker
    marker.usage["totalTokens"] if marker&.role == "assistant"
  end

  def summarised_since_last_reply? = context_marker&.role == "summary"

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
    update!(notes_file_bytes: state.dig("notesFile", "bytes"))
    @compacting = state["compaction"].present?
    @compaction_failed = state["compactionFailed"].present?
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
  def clear_live(after: 0, working: false, compacting: false, compaction_failed: false)
    broadcast_replace_to self, target: dom_id(self, :live), partial: "conversations/live",
      locals: { conversation: self, seq: [ after + 1, (Time.current.to_f * 1000).to_i ].max, working: working,
                compacting: compacting, compaction_failed: compaction_failed }
  end

  # A frame from the sidecar: the whole live reply so far, and what each
  # running tool has printed, morphed into the page so only what changed
  # moves; an older frame (lower seq) is dropped there. The last frame
  # (busy: false) carries no reply: the reply is a committed message by then,
  # so it is pulled onto the page first and only then the live tail clears and
  # the status settles. Nothing blinks out. It carries the conversation's
  # totals instead. Live output is never stored: the committed result
  # replaces it. A summary of earlier messages may be in the making, in a run
  # or (asked for) while the conversation is idle; the newest that failed is
  # said until one succeeds.
  # The last frame also says how large the notes file the conversation runs with is.
  def receive_frame(seq:, busy:, tail:, failure:, thinking: "", tools: [], usage: nil, compaction: nil, compaction_failed: nil, notes_file: nil)
    update!(failure: busy ? nil : failure.presence)
    if busy
      mark(invocations.awaiting_person.exists? ? "waiting" : "running")
      broadcast_replace_to self, target: dom_id(self, :live), partial: "conversations/live", attributes: { method: :morph },
        locals: { conversation: self, seq: seq, tail: tail.to_s, thinking: thinking.to_s, working: true,
                  compacting: compaction.present?, compaction_failed: compaction_failed.present? }
      tools.each { broadcast_tool_output(it, seq) }
    else
      pulled = pull
      mark(failure.present? ? "error" : "idle")
      clear_live(after: seq, compacting: compaction.present?, compaction_failed: compaction_failed.present?) if pulled
      update!(notes_file_bytes: notes_file&.dig("bytes"))
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

  def to_s = title.presence || "New agent"

  private
    def client = DurableAssistants::PiDurable::Client.new

    # The newest reply that measured its context, or a summary since.
    def context_marker
      messages.where(role: %w[ assistant summary ]).order(entry_id: :desc, id: :desc).limit(20)
        .detect { it.role == "summary" || it.usage.to_h["totalTokens"].to_i.positive? }
    end

    # The title in the header and in the sidebar's list.
    def broadcast_title
      %i[ title nav_title ].each { broadcast_update_to self, target: dom_id(self, it), html: ERB::Util.html_escape(to_s) }
    end

    # The bot's own tools show their ledger row, which says all there is; a
    # sidecar tool (the computer's shell, a browser) shows what it printed.
    # A nested call (a script's, a helper's) has no element of its own until
    # it prints, so its line is appended to its line's list, over the one
    # already there.
    def broadcast_tool_output(tool, seq)
      return if self.tool(tool["name"])
      call_id = tool["callId"]
      if (line = Invocation.line_call_id(call_id))
        Turbo::StreamsChannel.broadcast_append_to self, target: "#{Invocation.dom_target(line)}_calls", partial: "messages/live_tool_call",
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

    # Words alone go as a string; with pictures, as text and image blocks.
    def content_blocks(text, images)
      return text if images.empty?
      raise ImagesRefused, "Attach up to #{IMAGES_PER_MESSAGE} pictures to one message." if images.size > IMAGES_PER_MESSAGE
      [ ({ type: "text", text: text } if text.present?), *images.map { image_block(it) } ].compact
    end

    def image_block(file)
      raise ImagesRefused, "Each picture must be 5 MB or smaller." if file.size > IMAGE_BYTES
      bytes = file.read
      # What the bytes are, not what the browser called them.
      type = Marcel::MimeType.for(StringIO.new(bytes))
      raise ImagesRefused, "Only PNG, JPEG, WebP and GIF pictures can be sent." unless IMAGE_TYPES.key?(type)
      { type: "image", data: Base64.strict_encode64(bytes), mimeType: type }
    end

    def attach_image(message, image, index)
      type = image["mimeType"] if image.is_a?(Hash)
      return unless IMAGE_TYPES.key?(type) && image["data"].is_a?(String)
      bytes = Base64.strict_decode64(image["data"])
      return if bytes.bytesize > IMAGE_BYTES
      message.images.attach(io: StringIO.new(bytes), filename: "image-#{message.entry_key}-#{index}.#{IMAGE_TYPES[type]}", content_type: type)
    rescue ArgumentError
      nil
    end

    def bot_belongs_to_user
      errors.add(:bot, "belongs to someone else") if bot && user && bot.user_id != user_id
    end

    def parent_is_the_same_bots
      errors.add(:parent, "is another bot's conversation") if parent && parent.bot_id != bot_id
    end
end
