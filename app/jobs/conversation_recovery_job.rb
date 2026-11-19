# Every minute (config/recurring.yml), deliberately global: asks the sidecar where each conversation whose run
# goes, or may, stands (Conversation#refresh_status!): a final frame that never arrived settles, a run Rails
# can't vouch for is found out, and a run that stalled is ended (Conversation#recover). A wait the sidecar
# still holds for a call already answered here is rung, and logged, so the sidecar settles it; until it has,
# the run is unknown, never working (Conversation::AnsweredWaits). A card alone is not a
# run: one waiting after the run ended needs no sidecar. An outside call
# whose run ended mid-call is settled as lost, and logged (Invocation.settle_abandoned), and a
# handed-back card nobody answered ends (Invocation.settle_handed_back). A background helper whose end report
# never came is settled as failed, and logged, once the sidecar no longer runs it or it has been quiet too
# long (Helper.settle_lost).
class ConversationRecoveryJob < ApplicationJob
  def perform
    # `status` too: during a deploy, code from before execution_status starts runs it records only there.
    Conversation.where(execution_status: %w[ running unknown ]).or(Conversation.where(status: "running")).find_each do |conversation| # tenancy-ok: the recurring sweep covers every running conversation
      conversation.refresh_status!
    rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch
      next # unreachable now; the next minute asks again
    end
    Invocation.settle_abandoned
    Invocation.settle_handed_back
    Helper.settle_lost
  end
end
