# Stop the conversation's current run. Closing the page never does this.
class CancellationsController < ApplicationController
  def create
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    raise ActionController::BadRequest unless Agent::Access.valid_id?(params[:request_id])
    conversation.cancel(request_id: params[:request_id], preserve_queue: true)
    redirect_to conversation, status: :see_other
  end
end
