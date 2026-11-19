# What a paused agent's thread holds (Agent::Pausable): every send prepared
# since the pause and not yet accepted by the sidecar, the copies of what was
# taken back from its queue among them, in the order each was sent. Each is
# already its whole envelope (Conversation::Submission), so holding one is
# only not sending it yet, and resuming sends it as any retry would, once. A
# send that failed before the pause is not held, and the resume never sends it.
# Only the agent's thread holds: an old branch thread refuses a send while
# its agent is paused (Submission#deliver).
module Conversation::Holding
  extend ActiveSupport::Concern

  PAUSED = "Agent paused: your message is held until its owner resumes it.".freeze

  # A copy is dated at the pause (Submission#held_copy), so it goes before
  # whatever was held after it, as it was sent before.
  def held
    return submissions.none unless (since = holding_since)
    submissions.where(accepted_at: nil, created_at: since..).order(:created_at, :id)
  end

  # When the agent began holding, asked afresh: it may have been paused or
  # resumed since it was loaded.
  def holding_since = (Agent.where(id: agent_id).pick(:paused_at) unless parent_id) # tenancy-ok: this thread's own agent, by its id

  # The messages waiting in the sidecar as the agent is paused, taken back in
  # their order to be held. The sidecar keeps the first submission of each
  # request id, a withdrawn one too, so each is held as a copy of its envelope
  # under an id of its own (Submission#held_copy). The copy is made before the
  # withdrawal: a crash between leaves both, and the next pull-back
  # (ConversationHoldingJob) withdraws it under the same copy. One the agent
  # took in meanwhile is not held, unless it was accepted at or after the
  # pause: then the run it started was refused at its first step, so it is
  # held again, and the agent reads it twice. Once resumed, only what was sent
  # before the resume: what the resume sends is not taken back. An unreachable
  # sidecar raises, for the job to try again.
  def hold_queued
    return unless durable_id && (since = holding_since)
    sent = submissions.where(compacted_at: nil).where.not(accepted_at: nil)
    resumed = Agent.where(id: agent_id).pick(:resumed_at) # tenancy-ok: this thread's own agent, by its id
    sent = sent.where(accepted_at: ...resumed) if resumed
    queued = self.class.queued_from(client.snapshot(access, durable_id)["queued"])
    queued.each do |item|
      original = sent.find { it.receipt.to_h["id"].to_s == item["id"] }
      next unless original
      copy = original.held_copy(when_busy: item["mode"])
      if client.withdraw_queued(access, durable_id, item["id"])["withdrawn"] == true
        hold_again(original)
      else
        copy.destroy!
      end
    end
    sent.where(accepted_at: since..).each do |original|
      next if queued.any? { it["id"] == original.receipt.to_h["id"].to_s }
      original.held_copy
      hold_again(original)
    end
    broadcast_held
  end

  # Resumed: each held message goes as a retry of its own envelope would, in
  # order, those that came meanwhile included, until none is left; then, in
  # the same transaction as that last look, the agent stops holding. One the
  # sidecar refuses for good is logged, set aside unsent and said beside the
  # list. Any other error is said too, and raises: ConversationHoldingJob
  # goes on a minute later, still holding.
  def deliver_held
    return unless agent.reload.resuming?
    refused, said = [], nil
    while agent.reload.resuming?
      if (submission = held.where.not(id: refused).first)
        begin
          submission.deliver!
        rescue Conversation::Submission::Refused, Conversation::ImagesRefused, Conversation::Mismatch, DurableAssistants::PiDurable::Client::Error => refusal
          raise unless refused_for_good?(refusal)
          Rails.logger.warn "Held message #{submission.id} not delivered: #{refusal.class.name} #{refusal.try(:category)}"
          refused << submission.id
          said = "A held message wasn't sent: #{refusal_words(refusal)}"
        end
      else
        agent.with_lock { agent.update!(paused_at: nil, resumed_at: nil) unless held.where.not(id: refused).exists? }
      end
    end
    Rails.logger.info "Agent #{agent_id} sent what it held" unless agent.paused_at
    broadcast_held_problem said
    broadcast_held
    broadcast_row
  rescue => error
    broadcast_held_problem "Not everything held has gone yet: #{error.is_a?(DurableAssistants::PiDurable::Client::Error) ? "the agent is not reachable" : "something went wrong"}. Trying again in a minute."
    raise
  end

  # The waiting list as it is: the sidecar's and what is held. Nothing, if
  # the sidecar can't say, rather than a list that may be wrong.
  def broadcast_held
    durable_id ? broadcast_queued : broadcast_queued([])
  rescue DurableAssistants::PiDurable::Client::Error
    nil
  end

  private
    def hold_again(original)
      original.compact!
      peer_tasks.sent_as(original.request_id)&.answer("TASK_STATE_WORKING", PAUSED)
    end

    # What the sidecar's submit refuses about the message itself: bad JSON
    # (400), no such conversation (404), another body under its id (409), too
    # large (413), or invalid (422). Sent again, it is refused again. A wrong
    # token (401, 403), busy (429) or anything else is the app's or the
    # sidecar's state, so it is tried again.
    REFUSED_FOR_GOOD = [ 400, 404, 409, 413, 422 ].freeze

    def refused_for_good?(error)
      !error.is_a?(DurableAssistants::PiDurable::Client::Error) || error.status.in?(REFUSED_FOR_GOOD)
    end

    def refusal_words(refusal)
      case refusal
      when DurableAssistants::PiDurable::Client::Error then Conversation::Failure::REFUSALS.fetch(refusal.category, "the agent's server refused it.")
      when Conversation::Mismatch then "it was meant for an earlier thread."
      else refusal.message
      end
    end

    # Beside the waiting list, live only: the last problem a resume met, or nothing.
    def broadcast_held_problem(text)
      broadcast_replace_to self, target: dom_id(self, :held_problem), partial: "conversations/held_problem", locals: { conversation: self, text: text }
    end
end
