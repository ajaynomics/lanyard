# A message waiting for the agent, before it takes it in: made a steer or a
# follow-up (update), with first sent now, whoever sent it; or the person's own
# taken back (destroy), to drop or to edit in the box.
class Conversations::QueuedMessagesController < ApplicationController
  include QueuedMessageScoped

  def update
    raise ActionController::BadRequest unless Conversation::BUSY_MODES.include?(params[:when_busy])
    respond @conversation.change_queued(params[:id], when_busy: params[:when_busy], first: params[:first].present?)
  end

  def destroy
    respond @conversation.withdraw_queued(params[:id])
  end
end
