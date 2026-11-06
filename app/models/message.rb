# One message of Rails' copy of a conversation (see Conversation#sync!).
# Appended once per sidecar entry, in order, and shown as it arrives.
class Message < ApplicationRecord
  SHOWN = %w[ user assistant toolResult summary ].freeze

  belongs_to :conversation

  scope :shown, -> { where(role: SHOWN).order(:entry_id, :id) }

  after_create_commit :broadcast_appended, if: :shown?

  def shown? = SHOWN.include?(role)
  def from_person? = role == "user"

  # The ledger row behind a tool result, when the tool was one of the bot's.
  def invocation
    conversation.invocations.find_by(call_id: tool_call_id) if tool_call_id
  end

  private
    def broadcast_appended
      broadcast_append_to conversation, target: "messages", partial: "messages/message", locals: { message: self }
      # A sidecar tool (a computer's bash, say) has no ledger row to replace its
      # "Running…" line; its result, shown on its own, retires that line.
      broadcast_remove_to conversation, target: Invocation.dom_target(tool_call_id) if role == "toolResult" && tool_call_id && !invocation
    end
end
