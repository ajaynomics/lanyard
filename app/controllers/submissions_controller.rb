# A person's message to the bot. The reply arrives through the sidecar.
class SubmissionsController < ApplicationController
  def create
    conversation = Current.user.conversations.find(params[:conversation_id])
    content = params.expect(:content).to_s
    busy = params.fetch(:when_busy, "followUp")
    raise ActionController::BadRequest unless content.bytesize.between?(1, 65_536) && Conversation::BUSY_MODES.include?(busy) &&
      Agent::Access.valid_id?(params[:request_id])

    conversation.submit(content, request_id: params[:request_id], when_busy: busy)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("composer", partial: "conversations/composer", locals: { conversation: conversation }),
          turbo_stream.replace(helpers.dom_id(conversation, :live), partial: "conversations/live",
            locals: { conversation: conversation, seq: (Time.current.to_f * 1000).to_i, pending: content })
        ]
      end
      format.html { redirect_to conversation, status: :see_other }
    end
  end
end
