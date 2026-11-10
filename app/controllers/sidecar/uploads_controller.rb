module Sidecar
  # A file a call names, read from the agent's computer (agent/attachments.mjs)
  # before the call itself arrives, its bytes in base64. Kept against the call
  # (Upload) within the tool's limits.
  class UploadsController < PrivateController
    def create
      data = request.request_parameters
      tool = conversation.tool(data["tool"].to_s)
      limits = tool&.files_limits or return render(json: { error: "no_files" }, status: :unprocessable_content)
      Upload.store(conversation, task_id: data["taskId"].to_s, call_id: data["callId"].to_s, path: data["path"].to_s,
        bytes: Base64.strict_decode64(data["bytes"].to_s), **limits)
      head :no_content
    rescue ArgumentError, ActiveRecord::RecordInvalid
      render json: { error: "invalid_upload" }, status: :unprocessable_content
    rescue Upload::TooLarge
      render json: { error: "too_large" }, status: :content_too_large
    end
  end
end
