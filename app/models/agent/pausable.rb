# The person may pause an agent (#52). While paused it runs no model turn:
# Rails refuses the sidecar's access check, which it makes before every tool
# call and model request (Sidecar::AccessesController), so a turn under way
# stops at its next step, with no Stop that would cancel the cards waiting on
# the person. What anyone sends it from the pause on is held as its prepared
# envelope, unsent (Conversation::Holding); what was already waiting in the
# sidecar comes back to be held too.
#
# Resumed, it may run again at once, but it holds until ConversationHoldingJob
# has taken back what the sidecar was sent before the resume and sent
# everything held, in order: a message that comes meanwhile waits behind
# those. So paused_at marks what is held and resumed_at lets it run. A resume
# under way can't be paused: it finishes first. Only the agent's own thread
# holds; an old branch thread refuses a send while paused.
module Agent::Pausable
  extend ActiveSupport::Concern

  def paused? = paused_at.present? && resumed_at.nil?
  def resuming? = paused_at.present? && resumed_at.present?

  def pause
    return if paused_at
    update!(paused_at: Time.current)
    Rails.logger.info "Agent #{id} paused"
    return unless conversation
    # A send under way as the pause was saved lands in the sidecar after the
    # pull-back below; the job takes it back a moment later, or the resume's
    # does if that comes first, and retries an unreachable sidecar until it
    # answers. Enqueued first, so a crash between a copy and its withdrawal is
    # mended too.
    ConversationHoldingJob.set(wait: 5.seconds).perform_later(conversation)
    begin
      conversation.hold_queued
    rescue DurableAssistants::PiDurable::Client::Error => error
      Rails.logger.warn "Conversation #{conversation.id} not yet given back its waiting messages: #{error.category}"
    end
    conversation.broadcast_row
  end

  def resume
    return unless paused?
    return update!(paused_at: nil) unless conversation
    update!(resumed_at: Time.current)
    Rails.logger.info "Agent #{id} resumed"
    ConversationHoldingJob.perform_later(conversation)
    conversation.broadcast_row
  end
end
