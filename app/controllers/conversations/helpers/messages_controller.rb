# A person's words for a helper working in the background (Helper#message),
# read at its next step, from its line in the thread or the Helpers panel. Both
# show them by broadcast; a helper that already finished says so, as Cancel does.
class Conversations::Helpers::MessagesController < ApplicationController
  include RedrawnByBroadcast

  def create
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    helper = conversation.helpers.find(params[:helper_id])
    redrawn_by_broadcast helper.message(params.expect(:text)),
      refusal: "That helper had already finished, so it didn't get your message.", fallback: conversation
  end
end
