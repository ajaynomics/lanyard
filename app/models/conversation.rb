class Conversation < ApplicationRecord
  # The sidecar's store and this database disagree about which conversation a
  # request made (one restored without the other). Never guess.
  class Mismatch < StandardError; end

  STATUSES = %w[ idle running waiting done error cancelled blocked ].freeze
  BUSY_MODES = %w[ followUp steer ].freeze

  belongs_to :user
  belongs_to :bot
  has_many :invocations, dependent: :destroy

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
  end

  def cancel(request_id:)
    client.cancel(access, durable_id, request_id)
  end

  # A doorbell: it carries no decision. The sidecar re-sends the waiting call
  # and the ledger answers from what Rails recorded.
  def wake(invocation)
    client.wake(access, durable_id, invocation.wait_key)
  end

  def to_s = title.presence || "New conversation"

  private
    def client = DurableAssistants::PiDurable::Client.new

    def bot_belongs_to_user
      errors.add(:bot, "belongs to someone else") if bot && user && bot.user_id != user_id
    end
end
