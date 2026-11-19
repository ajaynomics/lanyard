# A person's message to the agent: words, pictures, other files, or any of
# them. The reply arrives through the sidecar.
class SubmissionsController < ApplicationController
  # A short message from the Watch, with its own token, as JSON.
  allow_watch_access only: :create

  def create
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    content = params.fetch(:content, "").to_s
    images = Array(params[:images]).grep(ActionDispatch::Http::UploadedFile)
    files = Array(params[:files]).grep(ActionDispatch::Http::UploadedFile)
    # The person's own words steer (#85) unless they chose Queue: the Watch and
    # a notice's Reply choose nothing.
    busy = params.fetch(:when_busy, "steer")
    raise ActionController::BadRequest unless (content.present? || images.any? || files.any?) && content.bytesize <= 65_536 &&
      Conversation::BUSY_MODES.include?(busy) && Agent::Access.valid_id?(params[:request_id])

    conversation.submit(content, request_id: params[:request_id], when_busy: busy, images: images, files: files, author: Current.user)
    # A share's pictures went with the message as the composer's own; the staged copies go now.
    Current.user.shares.find_by(id: params[:share_id])&.destroy if params[:share_id].present?
    ahoy.track "Message sent", agent_id: conversation.agent_id, pictures: images.size, files: files.size, when_busy: busy
    respond_to do |format|
      format.turbo_stream do
        # The page already shows the message (the echo controller). Only the
        # request id is renewed: the box keeps whatever the person has typed since.
        render turbo_stream: [ turbo_stream.replace("composer_request_id", partial: "conversations/request_id"),
          turbo_stream.update("composer_error", "") ]
      end
      format.html { redirect_to conversation, status: :see_other }
      # Accepted by the agent's server under this request id, not yet answered:
      # the same id again is the same message (the sidecar keeps one per id).
      format.json { render json: { conversation_id: conversation.id, request_id: params[:request_id], accepted: true }, status: :accepted }
    end
  rescue Conversation::Submission::TooLarge => refusal
    refuse(conversation, content, images, refusal, status: :unprocessable_entity, error: "too_large")
  rescue Conversation::Submission::Conflict => refusal
    refuse(conversation, content, images, refusal, status: :conflict, error: "conflict")
  rescue Conversation::ImagesRefused, Conversation::FilesRefused => refusal
    refuse(conversation, content, images, refusal, status: :unprocessable_entity, error: "refused")
  rescue Conversation::Submission::Paused => refusal
    refuse(conversation, content, images, refusal, status: :conflict, error: "paused")
  end

  private
    def refuse(conversation, content, images, refusal, status:, error:)
      respond_to do |format|
        # A failed send leaves its request id alone; the echo restores the words and pictures.
        format.turbo_stream { render turbo_stream: turbo_stream.update("composer_error", refusal.message), status: status }
        format.html do
          share = Current.user.shares.new(text: content, submission_request_id: params[:request_id])
          refusals = share.stage(images)
          share.save!
          redirect_to conversation_path(conversation, share: share), alert: ([ refusal.message ] + refusals).join(" "), status: :see_other
        end
        format.json { render json: { error: error, message: refusal.message }, status: status }
      end
    end
end
