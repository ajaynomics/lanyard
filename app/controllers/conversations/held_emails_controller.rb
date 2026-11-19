# A person's Cancel for mail held for its agent's sending hours
# (HeldEmail#cancel): it is never sent, and the agent is told. The card is
# redrawn by broadcast; one already sent or cancelled says so.
class Conversations::HeldEmailsController < ApplicationController
  include RedrawnByBroadcast

  def destroy
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    held = conversation.held_emails.find(params[:id])
    redrawn_by_broadcast held.cancel(by: Current.user), refusal: "That email was already sent or cancelled.", fallback: conversation
  end
end
