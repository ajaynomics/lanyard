# A person's Cancel for a helper the agent started in the background (Helper),
# from its line in the thread or the Helpers panel. Both are redrawn by
# broadcast; one that already finished says so.
class Conversations::HelpersController < ApplicationController
  include RedrawnByBroadcast

  def destroy
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    helper = conversation.helpers.find(params[:id])
    redrawn_by_broadcast helper.cancel, refusal: "That helper had already finished.", fallback: conversation
  end
end
