# A message waiting for the agent in one of the person's threads, and the
# answer to a control on it: the list on the page is redrawn by broadcast, so
# only a refusal (the agent has read it already) comes back.
module QueuedMessageScoped
  extend ActiveSupport::Concern

  included do
    before_action { @conversation = find_in_workspace(:conversations, params[:conversation_id]) }
  end

  private
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
