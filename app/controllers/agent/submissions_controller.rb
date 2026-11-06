module Agent
  class SubmissionsController < BaseController
    BUSY = %w[steer followUp].freeze

    def create
      content = request.request_parameters["content"]
      busy = request.request_parameters.fetch("when_busy", "followUp")
      raise ActionController::BadRequest unless content.is_a?(String) && content.bytesize.between?(1, 65_536) && BUSY.include?(busy)
      result = client.submit(@access, conversation.durable_id, request_id: request_id, content: content, when_busy: busy)
      respond_to do |format|
        format.html { back_to_conversation }
        format.json { render json: result, status: :accepted }
      end
    end
  end
end
