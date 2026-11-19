# A waiting message, whoever sent it, moved one place up or down the queue.
class Conversations::QueuedMessages::PositionsController < ApplicationController
  include QueuedMessageScoped

  def update
    raise ActionController::BadRequest unless Conversation::QUEUE_MOVES.include?(params[:to])
    respond @conversation.move_queued(params[:queued_message_id], to: params[:to])
  end
end
