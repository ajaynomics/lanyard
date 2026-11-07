# Summarise a conversation's earlier messages now (/compact), optionally
# saying what the summary should keep. The sidecar makes it while the
# conversation goes on; the page shows it in the making and then in place.
class Conversations::CompactionsController < ApplicationController
  def create
    conversation = Current.user.conversations.find(params[:conversation_id])
    instructions = params[:instructions].to_s.strip.presence
    raise ActionController::BadRequest unless Agent::Access.valid_id?(params[:request_id]) &&
      instructions.to_s.length <= Conversation::COMPACTION_INSTRUCTIONS

    conversation.compact(request_id: params[:request_id], instructions: instructions)
    redirect_to conversation, status: :see_other
  end
end
