# The waits the sidecar's snapshot still holds (`pendingInputs`, each
# `person:<Invocation#wait_key>`) for calls this ledger has already answered.
# A call ends its waits however it ends (agent/extensions.mjs `endWaits`); one
# that ended before that rule left its wait behind, and a snapshot whose only
# waits are these says "waiting" for a run that may already have ended.
# Ringing each wait's doorbell lets a waiting call fetch its answer and the
# sidecar settle a wait whose call has ended.
class Conversation::AnsweredWaits
  FINAL = %w[ succeeded failed denied ].freeze

  attr_reader :conversation, :keys

  def initialize(conversation, pending_inputs)
    @conversation = conversation
    @keys = Array(pending_inputs).filter_map { it["id"].to_s.delete_prefix("person:") if it.is_a?(Hash) && it["id"].to_s.start_with?("person:") }
  end

  # Every wait the snapshot holds is on an answered call: none is a wait.
  def all? = keys.any? && invocations.size == keys.size

  def invocations
    @invocations ||= keys.filter_map { |key| answered(*key.split(":", 2)) }
  end

  # Logged one by one, each the doorbell a person's answer rings.
  def ring
    invocations.each do |invocation|
      Rails.logger.info "Ringing the sidecar's wait #{invocation.wait_key} of conversation #{conversation.id}: " \
        "invocation #{invocation.id} is already #{invocation.state}"
      InvocationWakeJob.perform_later(invocation)
    end
  end

  private
    def answered(task_id, call_id)
      conversation.invocations.find_by(task_id: task_id, call_id: call_id, state: FINAL) if call_id
    end
end
