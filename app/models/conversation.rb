class Conversation < ApplicationRecord
  include ActionView::RecordIdentifier

  # The sidecar's store and this database disagree about which conversation a
  # request made (one restored without the other). Never guess.
  class Mismatch < StandardError; end

  STATUSES = %w[ idle running waiting error ].freeze
  BUSY_MODES = %w[ followUp steer ].freeze
  PAGE = 200

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
    mark("running")
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
      messages.delete_all
      update!(last_entry_id: nil)
    end
    sync!
  end

  # A frame from the sidecar: the whole live reply so far. The page replaces
  # its live tail with it; an older frame (lower seq) is dropped there.
  def receive_frame(seq:, busy:, tail:, failure:)
    sync! unless busy # the committed reply is on the page before the tail clears
    update!(failure: busy ? nil : failure.presence)
    mark(busy ? (invocations.awaiting_person.exists? ? "waiting" : "running") : (failure.present? ? "error" : "idle"))
    broadcast_replace_to self, target: dom_id(self, :live), partial: "conversations/live",
      locals: { conversation: self, seq: seq, tail: busy ? tail.to_s : "" }
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

    def record_entry(entry)
      return unless entry.is_a?(Hash) && entry["id"].present? && entry["entryId"].is_a?(Integer)
      messages.create_or_find_by!(entry_key: entry["id"].to_s) do |message|
        message.entry_id = entry["entryId"]
        message.role = entry["role"].to_s
        message.content = entry["content"].to_s
        message.tool_name = entry["toolName"]
        message.tool_call_id = entry["toolCallId"]
        message.tool_calls = Array(entry["toolCalls"]).map { it.slice("id", "name") }
        message.error = entry["isError"] == true
      end
    end

    def bot_belongs_to_user
      errors.add(:bot, "belongs to someone else") if bot && user && bot.user_id != user_id
    end
end
