# A message the person sent while the agent worked, before the agent takes it
# in: made a steer or a follow-up (update), or taken back (destroy), to drop or
# to edit in the box. The list on the page is redrawn by broadcast either way.
class Conversations::QueuedMessagesController < ApplicationController
  before_action :set_conversation

  def update
    raise ActionController::BadRequest unless Conversation::BUSY_MODES.include?(params[:when_busy])
    respond @conversation.change_queued(params[:id], when_busy: params[:when_busy])
  end

  def destroy
    respond @conversation.withdraw_queued(params[:id])
  end

  private
    def set_conversation
      @conversation = Current.user.conversations.find(params[:conversation_id])
    end

    def respond(done)
      notice = "#{@conversation.agent} has already read that message." unless done
      respond_to do |format|
        # A refusal is a failed submission, so its words don't go back in the box (echo#recall).
        format.turbo_stream do
          render turbo_stream: turbo_stream.update("composer_error", notice.to_s), status: done ? :ok : :conflict
        end
        format.html { redirect_to @conversation, alert: notice, status: :see_other }
      end
    end
end
