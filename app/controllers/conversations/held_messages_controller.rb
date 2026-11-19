# A message held while its agent is paused (Conversation::Holding), dropped
# by the person: the agent never reads it. Once a resume has begun it is too
# late, and the person is told. The list on the page is redrawn by broadcast.
class Conversations::HeldMessagesController < ApplicationController
  def destroy
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    if conversation.held.find(params[:id]).drop
      ahoy.track "Held message dropped", agent_id: conversation.agent_id
    else
      error = "Too late to drop: #{conversation.agent} is being sent what it held."
    end
    conversation.broadcast_held
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.update("composer_error", error.to_s) }
      format.html { redirect_to conversation, alert: error, status: :see_other }
    end
  end
end
