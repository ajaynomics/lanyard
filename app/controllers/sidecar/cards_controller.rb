module Sidecar
  # An approved payment's one-time card, for the sidecar to type into the
  # agent's checkout page once the call has run (Tool::PayByCard,
  # Invocation#redeem_card). It answers the sidecar alone, once per call, and
  # the card is never stored or logged here.
  class CardsController < PrivateController
    def create
      invocation = conversation.invocations.find_by!(task_id: request.request_parameters["taskId"].to_s,
        call_id: request.request_parameters["callId"].to_s)
      card = invocation.redeem_card
      return render json: { error: "card_used" }, status: :gone unless card
      response.set_header("Cache-Control", "no-store")
      render json: card
    rescue DurableAssistants::Link::Error => error
      render json: { error: "link", message: error.message }, status: :bad_gateway
    end
  end
end
