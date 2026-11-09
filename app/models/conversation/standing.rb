# Where an agent's thread stands in the agent list (conversations/_conversation),
# and the list kept in step as it changes. In the order the list sorts them:
#
# - needs_you: a card waits on the person (an approval, a question, a sign-in);
# - error: the last run stopped on an error;
# - unread: the agent has answered since the person last opened the thread;
# - working: a run is going, using `current_tool` if any;
# - idle: nothing to say;
# - stopped: the agent's computer is off.
#
# Each change the row shows is broadcast as that one row, replaced on the
# person's list stream; a new or unarchived thread is added, an archived one
# removed. The list's controller (agent_list_controller) puts a changed row in
# its place, by the rank and time each row carries; it also drops a row
# loaded twice (live, then again with a later page) and marks the open one,
# which a broadcast can't know. A reply that arrives while its thread is open
# and in view is read at once (reading_controller, Conversations::Readings).
module Conversation::Standing
  extend ActiveSupport::Concern

  STATES = %w[ needs_you error unread working idle stopped ].freeze
  # What a row shows that is the thread's own; a new message and a new title are told separately.
  SHOWN = %w[ status failure read_at replied_at current_tool ].freeze

  RANK = Arel.sql(<<~SQL.squish)
    CASE WHEN conversations.status = 'waiting' THEN 0
         WHEN conversations.status = 'error' THEN 1
         WHEN conversations.replied_at > COALESCE(conversations.read_at, '') THEN 2
         WHEN conversations.status = 'running' THEN 3
         WHEN EXISTS (SELECT 1 FROM computers WHERE computers.agent_id = conversations.agent_id AND computers.state = 'off') THEN 5
         ELSE 4 END
  SQL

  included do
    # What needs the person first, then the newest.
    scope :by_standing, -> { order(RANK, last_message_at: :desc, id: :desc) }

    after_create_commit :broadcast_row_added, unless: :parent_id?
    after_update_commit :broadcast_row_moved, if: -> { !parent_id? && saved_change_to_archived_at? }
    after_update_commit :broadcast_row, if: -> { !parent_id? && !saved_change_to_archived_at? && saved_changes.keys.intersect?(SHOWN) }
  end

  def standing
    if waiting? then "needs_you"
    elsif status == "error" then "error"
    elsif unread? then "unread"
    elsif status == "running" then "working"
    elsif agent.computer&.state == "off" then "stopped"
    else "idle"
    end
  end

  def standing_rank = STATES.index(standing)

  def unread? = replied_at.present? && (read_at.nil? || replied_at > read_at)

  # Only the time, whatever else the thread holds unsaved (a sync it refused).
  def read!
    update_columns(read_at: Time.current)
    broadcast_row
  end

  # A turn has come in (Message): a reply to the person makes the thread
  # unread until they open it, and either moves it up the list.
  def heard(message)
    update_column(:replied_at, message.created_at) if message.answer? && (replied_at.nil? || message.created_at > replied_at)
    broadcast_row
  end

  # What the card waiting on the person asks, for the row's line.
  def waiting_for
    Invocation.where(conversation_id: id).awaiting_person.order(:id).last&.card_title # tenancy-ok: this conversation's own cards
  end

  def broadcast_row
    return if parent_id? || archived?
    Turbo::StreamsChannel.broadcast_replace_to [ user, :conversations ], target: dom_id(self, :row), attributes: { method: :morph },
      partial: "conversations/conversation", locals: { conversation: listed }
  end

  private
    def broadcast_row_added
      return if archived?
      Turbo::StreamsChannel.broadcast_prepend_to [ user, :conversations ], target: "agents_list",
        partial: "conversations/conversation", locals: { conversation: listed }
    end

    def broadcast_row_moved
      if archived? then Turbo::StreamsChannel.broadcast_remove_to [ user, :conversations ], target: dom_id(self, :row)
      else broadcast_row_added
      end
    end

    # This thread as the list loads it: with its newest words and its agent's computer.
    def listed = user.conversations.with_preview.includes(agent: :computer).find(id)
end
