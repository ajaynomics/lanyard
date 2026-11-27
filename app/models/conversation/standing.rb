# Where an agent's thread stands in the agent list (conversations/_conversation),
# and the list kept in step as it changes. A row shows one of these:
#
# - needs_you: a card waits on the person (an approval, a question, a sign-in);
# - error: the last run stopped on an error;
# - unread: the agent has answered since the person last opened the thread;
# - working: a run is going, using `current_tool` if any;
# - unknown: Rails can't vouch for the run until the sidecar is next asked
#   (Conversation::Activity), so it says neither working nor idle;
# - idle: nothing to say;
# - stopped: the agent's computer is off.
#
# The list sorts by `listed_at`, the last news for the person: a card that
# starts waiting on them, or a reply to them (#bumps_sidebar?). Nothing else
# moves a row: tool calls, working and idle, errors and reads change it where
# it is, so the list stays still enough to click.
#
# Only structural changes reload the workspace tree. A status change morphs
# just the row so it stays in its branch and doesn't close the row's menu.
module Conversation::Standing
  extend ActiveSupport::Concern

  STATES = %w[ needs_you error unread working unknown idle stopped ].freeze
  # What a row shows that is the thread's own; a new message and a new title are told separately.
  SHOWN = %w[ status failure read_at replied_at current_tool listed_at ].freeze

  included do
    attribute :listed_at, default: -> { Time.current }

    # The last news for the person first.
    scope :by_news, -> { order(listed_at: :desc, id: :desc) }

    before_update :bump, if: :bumps_sidebar?

    after_create_commit -> { workspace.broadcast_reporting_tree }, unless: :parent_id?
    after_update_commit :broadcast_tree_change, if: -> { !parent_id? && saved_change_to_archived_at? }
    after_update_commit :broadcast_row, if: -> { !parent_id? && !saved_change_to_archived_at? && saved_changes.keys.intersect?(SHOWN) }
  end

  def standing
    if waiting? then "needs_you"
    elsif status == "error" then "error"
    elsif unread? then "unread"
    elsif shown_status == "unknown" then "unknown"
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
    return if parent_id?
    row = listed
    Turbo::StreamsChannel.broadcast_replace_to [ row.workspace, :conversations ], target: dom_id(self, :row), attributes: { method: :morph },
      partial: "conversations/conversation", locals: { conversation: row, waiting: invocations.waiting_on_person.size }
  end

  private
    # An archived row leaves at once, rather than after the tree's reload
    # (a whole list fetched and drawn again), which on a slow line or a busy
    # machine lags by seconds. Unarchiving waits for the reload: only the tree
    # knows where the row goes back.
    def broadcast_tree_change
      Turbo::StreamsChannel.broadcast_remove_to [ workspace, :conversations ], target: dom_id(self, :row) if archived?
      workspace.broadcast_reporting_tree
    end

    def bump = self.listed_at = Time.current

    # This thread as the list loads it: with its newest words and its agent's computer.
    def listed = agent.conversations.with_preview.includes(agent: :computer).find(id)
end
