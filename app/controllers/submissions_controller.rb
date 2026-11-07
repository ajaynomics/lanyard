# A person's message to the bot: words, pictures, or both. The reply arrives
# through the sidecar.
class SubmissionsController < ApplicationController
  def create
    conversation = Current.user.conversations.find(params[:conversation_id])
    content = params.fetch(:content, "").to_s
    images = Array(params[:images]).grep(ActionDispatch::Http::UploadedFile)
    busy = params.fetch(:when_busy, "followUp")
    raise ActionController::BadRequest unless (content.present? || images.any?) && content.bytesize <= 65_536 &&
      Conversation::BUSY_MODES.include?(busy) && Agent::Access.valid_id?(params[:request_id])

    conversation.submit(content, request_id: params[:request_id], when_busy: busy, images: images)
    conversation.unarchive
    respond_to do |format|
      format.turbo_stream do
        # The page already shows the message (the echo controller). Only the
        # request id is renewed: the box keeps whatever the person has typed since.
        render turbo_stream: [ turbo_stream.replace("composer_request_id", partial: "conversations/request_id"),
          turbo_stream.update("composer_error", "") ]
      end
      format.html { redirect_to conversation, status: :see_other }
    end
  rescue Conversation::ImagesRefused => refusal
    respond_to do |format|
      # The echo goes and the words and pictures go back in the box; the reason shows above it.
      format.turbo_stream { render turbo_stream: turbo_stream.update("composer_error", refusal.message), status: :unprocessable_entity }
      format.html { redirect_to conversation, alert: refusal.message, status: :see_other }
    end
  end
end
