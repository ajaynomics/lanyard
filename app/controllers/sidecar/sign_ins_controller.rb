module Sidecar
  # A saved sign-in's password, for the sidecar to type into the agent's
  # browser once the person has approved the call that asked for it
  # (Tool::SignInWithSavedPassword, Invocation#redeem_sign_in). It answers the
  # sidecar alone, once per approved call, and is never stored or logged here.
  class SignInsController < PrivateController
    def create
      invocation = conversation.invocations.find_by!(task_id: request.request_parameters["taskId"].to_s,
        call_id: request.request_parameters["callId"].to_s)
      sign_in = invocation.redeem_sign_in
      return render json: { error: "sign_in_used" }, status: :gone unless sign_in
      response.set_header("Cache-Control", "no-store")
      render json: { host: sign_in.host, username: sign_in.username, password: sign_in.password }
    rescue DurableAssistants::Passbolt::Error => error
      render json: { error: "password_manager", message: error.message }, status: :bad_gateway
    end
  end
end
