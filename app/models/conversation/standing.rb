# Where an agent's thread stands in the agent list (conversations/_conversation),
# and the list kept in step as it changes. A row shows one of these:
#
# - needs_you: a card waits on the person (an approval, a question, a sign-in);
# - error: the last run stopped on an error;
# - unread: the agent has answered since the person last opened the thread;
# - working: a run is going, using `current_tool` if any;
# - idle: nothing to say;
# - stopped: the agent's computer is off.
#
# The list sorts by `listed_at`, the last news for the person: a card that
# starts waiting on them, or a reply to them (#bumps_sidebar?). Nothing else
# moves a row: tool calls, working and idle, errors and reads change it where
# it is, so the list stays still enough to click.
#
# Each change the row shows is broadcast as that one row, replaced on the
# person's list stream; a new or unarchived thread is added, an archived one
# removed. The list's controller (sidebar_order_controller) puts a moved row
# in its place, by the time each row carries, once the person's hand is off
# the list; it also drops a row loaded twice (live, then again with a later
# page) and marks the open one, which a broadcast can't know. A reply that arrives while its thread is open
# and in view is read at once (reading_controller, Conversations::Readings).
module Conversation::Standing
  extend ActiveSupport::Concern

  STATES = %w[ needs_you error unread working idle stopped ].freeze
  # What a row shows that is the thread's own; a new message and a new title are told separately.
  SHOWN = %w[ status failure read_at replied_at current_tool listed_at ].freeze

  included do
    attribute :listed_at, default: -> { Time.current }

    # The last news for the person first.
    scope :by_news, -> { order(listed_at: :desc, id: :desc) }

    before_update :bump, if: :bumps_sidebar?

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

  def unread? = replied_at.present? && (read_at.nil? || replied_at > read_at)

  # Only the time, whatever else the thread holds unsaved (a sync it refused).
  def read!
    update_columns(read_at: Time.current)
    broadcast_row
  end

  # A turn has come in (Message): a reply to the person makes the thread
  # unread until they open it, and moves it to the top of the list.
  def heard(message)
    if bumps_sidebar?(message)
      update_columns(replied_at: message.created_at, listed_at: [ listed_at, message.created_at ].compact.max)
    end
    broadcast_row
  end

  # News for the person: a reply to them, or, saving the thread, a card that
  # starts waiting on them. Answering the card is not news; the reply after it is.
  def bumps_sidebar?(message = nil)
    if message then message.answer? && (replied_at.nil? || message.created_at > replied_at)
    else will_save_change_to_status?(to: "waiting")
    end
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

    def bump = self.listed_at = Time.current

    # This thread as the list loads it: with its newest words and its agent's computer.
    def listed = user.conversations.with_preview.includes(agent: :computer).find(id)
end
