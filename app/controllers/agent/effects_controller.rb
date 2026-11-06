module Agent
  class EffectsController < PrivateController
    def create
      data = request.request_parameters
      raise Effect::Conflict unless data["tool"] == "rails_note"
      result = Effect.record_note!(access, task_id: data["taskId"], call_id: data["callId"],
        arguments: data["arguments"], digest: data["digest"])
      render json: result
    end
  end
end
