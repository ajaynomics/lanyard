# A person's Revoke for a link an agent made for someone outside to fill a
# saved sign-in (SignInLink#revoke): it takes nothing more, and the agent is
# told it was not filled. The card is redrawn by broadcast; one already used,
# revoked or expired says so.
class Conversations::SignInLinksController < ApplicationController
  include RedrawnByBroadcast

  def destroy
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    link = conversation.sign_in_links.find(params[:id])
    redrawn_by_broadcast link.revoke(by: Current.user), refusal: "That link was already used, revoked or expired.", fallback: conversation
  end
end
