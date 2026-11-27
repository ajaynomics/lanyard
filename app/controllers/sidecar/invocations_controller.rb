module Sidecar
  # Every tool call the sidecar's model makes comes here. The answer is either
  # the call's result ("done") or "waiting" while a person decides; the
  # sidecar holds that wait and asks again when its doorbell rings. With
  # `handBack`, messages wait for the agent: Rails takes an approval's card
  # back ("handedBack") and finishes the call itself (Invocation#hands_back?).
  class InvocationsController < PrivateController
    rescue_from Invocation::Conflict, with: -> { render json: { error: "invocation_conflict" }, status: :conflict }

    def create
      data = request.request_parameters
      render json: Invocation.receive(conversation, task_id: data["taskId"], call_id: data["callId"],
        tool: data["tool"], arguments: data["arguments"], digest: data["digest"], hand_back: data["handBack"] == true,
        phone: data["phone"] == true)
    end
  end
end
