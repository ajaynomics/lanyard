module Sidecar
  class HeldPostsController < PrivateController
    rescue_from Invocation::Conflict, with: -> { render json: { error: "held_post_conflict" }, status: :conflict }

    def create
      held = Approval::OutsideSend.new(conversation, request.request_parameters["held_post"])
      decision = case request.request_parameters["operation"]
      when "open" then held.open
      when "answer" then held.answer
      when "cancel" then held.cancel
      else raise Invocation::Conflict
      end
      render json: { status: decision }
    end
  end
end
