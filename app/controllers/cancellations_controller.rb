# Stop the conversation's current run. Closing the page never does this.
class CancellationsController < ApplicationController
  def create
    conversation = Current.user.conversations.find(params[:conversation_id])
    raise ActionController::BadRequest unless Agent::Access.valid_id?(params[:request_id])
    conversation.cancel(request_id: params[:request_id])
    redirect_to conversation, status: :see_other
  end
end
