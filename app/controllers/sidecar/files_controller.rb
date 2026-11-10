module Sidecar
  # A file a Google tool found (Invocation#file?), for the sidecar to save on
  # the agent's computer (agent/files.mjs): fetched from Google with the
  # connector's own sign-in, soon after the call, and never stored here.
  class FilesController < PrivateController
    def create
      invocation = conversation.invocations.find_by!(task_id: request.request_parameters["taskId"].to_s,
        call_id: request.request_parameters["callId"].to_s)
      bytes = invocation.download_file
      return render json: { error: "file_gone" }, status: :gone unless bytes
      response.set_header("Cache-Control", "no-store")
      send_data bytes, type: "application/octet-stream", disposition: "attachment"
    rescue DurableAssistants::Google::Error, McpServer::SignInNeeded => error
      render json: { error: "google", message: error.message.truncate(300) }, status: :bad_gateway
    end
  end
end
