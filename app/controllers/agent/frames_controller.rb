module Agent
  # The live reply while a run streams, about ten times a second.
  class FramesController < PrivateController
    def create
      data = request.request_parameters
      raise ActionController::BadRequest unless data["seq"].is_a?(Integer) && [ true, false ].include?(data["busy"])
      conversation.receive_frame(seq: data["seq"], busy: data["busy"], tail: data["tail"].to_s.first(200_000),
        thinking: data["thinking"].to_s.first(200_000), failure: data["failure"], tools: tools(data["tools"]),
        usage: (data["usage"] if data["usage"].is_a?(Hash)))
      head :no_content
    end

    private
      # The sidecar sends at most 4 KB of each call's output; a little slack for
      # characters, and a bound on the list, in case it ever sends more.
      def tools(list)
        Array(list).first(64).filter_map do |tool|
          next unless tool.is_a?(Hash) && tool["callId"].is_a?(String) && tool["callId"].match?(Invocation::CALL_ID) && tool["name"].is_a?(String)
          { "callId" => tool["callId"], "name" => tool["name"].first(64), "status" => tool["status"].to_s, "output" => tool["output"].to_s.last(8_000) }
        end
      end
  end
end
