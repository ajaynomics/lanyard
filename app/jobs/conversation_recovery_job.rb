# Every minute (config/recurring.yml), deliberately global: asks the sidecar where each busy conversation stands
# (Conversation#refresh_status!): a final frame that never arrived settles,
# and a run that stalled is ended (Conversation#recover).
class ConversationRecoveryJob < ApplicationJob
  def perform
    Conversation.where(status: %w[ running waiting ]).find_each do |conversation| # tenancy-ok: the recurring sweep covers every busy conversation
      conversation.refresh_status!
    rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch
      next # unreachable now; the next minute asks again
    end
  end
end
