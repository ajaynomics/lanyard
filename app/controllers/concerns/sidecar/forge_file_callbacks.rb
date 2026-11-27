module Sidecar::ForgeFileCallbacks
  private
    def forge_mode = request.headers["X-Forge-Mode"]

    def forge_session(mode)
      raise ForgeFiles::Invalid if request.query_string.present?
      scope = Agent::Access.resolve(request.headers["X-Forge-Actor"], request.headers["X-Forge-Agent"])
      conversation = scope.agent.conversations.find_by!(durable_id: request.headers["X-Forge-Conversation"])
      invocation = conversation.invocations.find_by!(task_id: request.headers["X-Forge-Task"], call_id: request.headers["X-Forge-Call"])
      ForgeFiles::Binding.check!(invocation)
      [ ForgeFiles::Session.find(invocation, request.headers["X-Forge-Transfer"], mode), invocation ]
    end

    def empty_forge_request!
      raise ForgeFiles::Invalid unless request.get_header("CONTENT_LENGTH").to_s.in?([ "", "0" ]) &&
        request.get_header("HTTP_TRANSFER_ENCODING").blank?
    end

    def forge_download
      raise Agent::Access::Forbidden unless forge_mode == "stage"
      session, = forge_session("stage")
      empty_forge_request!
      file = session.open
      response.set_header("Cache-Control", "no-store")
      response.set_header("Content-Length", session.bytes.to_s)
      response.content_type = "application/octet-stream"
      self.response_body = Stream.new(file)
    rescue Errno::ENOENT
      head :not_found
    rescue ForgeFiles::Invalid, IOError, SystemCallError
      head :unprocessable_content
    end

    def forge_upload
      raise Agent::Access::Forbidden unless forge_mode.in?(%w[ push-check push ])
      session, invocation = forge_session("push")
      if forge_mode == "push-check"
        empty_forge_request!
        return head :no_content
      end

      length = request.get_header("CONTENT_LENGTH").to_s
      raise ForgeFiles::TooLarge if length.match?(/\A\d{1,20}\z/) && length.to_i > ForgeFiles::MAX_BYTES
      raise ForgeFiles::Invalid unless request.get_header(DurableAssistants::ForgeBody::CONTENT_TYPE) == DurableAssistants::ForgeBody::BINARY &&
        length == session.bytes.to_s

      Timeout.timeout(60) do
        session.store(request.body_stream) { ForgeFiles::Binding.check!(invocation) }
      end
      head :no_content
    rescue ForgeFiles::TooLarge
      head :content_too_large
    rescue ForgeFiles::Busy
      head :conflict
    rescue ForgeFiles::Invalid, IOError, SystemCallError, Timeout::Error
      head :unprocessable_content
    end

    class Stream
      def initialize(file) = @file = file

      def each
        while (chunk = @file.read(ForgeFiles::CHUNK_BYTES))
          yield chunk
        end
      rescue IOError, SystemCallError
        raise IOError, "forge_file_transfer_failed", cause: nil
      end

      def close = @file.close
    end
end
