module Agent
  # The live reply while a run streams, about ten times a second.
  class FramesController < PrivateController
    def create
      data = request.request_parameters
      raise ActionController::BadRequest unless data["seq"].is_a?(Integer) && [ true, false ].include?(data["busy"])
      conversation.receive_frame(seq: data["seq"], busy: data["busy"], tail: data["tail"].to_s.first(200_000),
        thinking: data["thinking"].to_s.first(200_000), failure: data["failure"])
      head :no_content
    end
  end
end
