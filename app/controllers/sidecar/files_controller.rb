module Sidecar
  # A file a tool found (Invocation#file?), for the sidecar to save on the
  # agent's computer (agent/files.mjs): fetched from Google with the
  # connector's own sign-in, from the office's wiki at its own address, from
  # a connector's own address, or from the Mac's BlueBubbles, soon after the
  # call. A file of any size: one fetched to disk streams from there with its
  # length, and is removed once sent.
  class FilesController < PrivateController
    def create
      invocation = conversation.invocations.find_by!(task_id: request.request_parameters["taskId"].to_s,
        call_id: request.request_parameters["callId"].to_s)
      index = request.request_parameters["index"]
      found = invocation.download_file(index.is_a?(Integer) ? index : 0)
      return render json: { error: "file_gone" }, status: :gone unless found
      response.set_header("Cache-Control", "no-store")
      return send_data found, type: "application/octet-stream", disposition: "attachment" if found.is_a?(String)
      response.set_header("Content-Length", found.size.to_s)
      response.set_header("Content-Disposition", "attachment")
      response.content_type = "application/octet-stream"
      self.response_body = Body.new(found)
    rescue DurableAssistants::Google::Error, McpServer::SignInNeeded => error
      render json: { error: "google", message: error.message.truncate(300) }, status: :bad_gateway
    rescue McpServer::Unreachable => error
      render json: { error: "connector", message: error.message.truncate(300) }, status: :bad_gateway
    rescue DurableAssistants::Bluebubbles::Error => error
      render json: { error: "bluebubbles", message: error.message.truncate(300) }, status: :bad_gateway
    rescue DurableAssistants::Telegram::Error, TelegramBot::SignInError => error
      render json: { error: "telegram", message: error.message.truncate(300) }, status: :bad_gateway
    end

    # A Tempfile as a Rack body: read a MiB at a time (or sent by its path),
    # and deleted when the server closes the body, however the send ended.
    class Body
      def initialize(file) = @file = file

      def to_path = @file.path

      def each
        @file.rewind
        while (chunk = @file.read(1.megabyte))
          yield chunk
        end
      end

      def close = @file.close!
    end
  end
end
