module Sidecar
  # A background helper's news (agent/subagent.mjs): that it is working and
  # on what, then how it ended, whose answer goes to the conversation. The
  # same report twice changes nothing. A failure answers 500 and the sidecar
  # tells it again later.
  class HelpersController < PrivateController
    # A route the helper ran on, "provider/model".
    MODEL = %r{\A[\w.-]{1,50}/[\w.:-]{1,150}\z}

    def create
      data = request.request_parameters
      raise ActionController::BadRequest unless data["state"].in?(%w[ running done failed ]) &&
        data["callId"].is_a?(String) && data["callId"].match?(Invocation::CALL_ID) && data["task"].is_a?(String) &&
        (data["model"].nil? || (data["model"].is_a?(String) && data["model"].match?(MODEL))) &&
        (data["thinking"].nil? || data["thinking"].in?(Agent::THINKING_LEVELS))
      Helper.report(conversation, call_id: data["callId"], task: data["task"], state: data["state"],
        model: data["model"], thinking_level: data["thinking"],
        answer: (data["answer"].to_s.first(Conversation::WORDS_LIMIT) if data["state"] == "done"),
        reason: (data["reason"].to_s.first(100) if data["state"] == "failed"),
        calls: calls(data["tools"]), count: (data["count"] if data["count"].is_a?(Integer)).to_i,
        usage: (data["usage"] if data["usage"].is_a?(Hash)))
      head :no_content
    rescue Conversation::Submission::Refused => refusal
      render json: { error: "submission_refused", message: refusal.message }, status: :service_unavailable
    end

    private
      # As the helper's line keeps them: what each was given, how it ended and
      # the end of what came back, bounded as frames are.
      def calls(list)
        Array(list).last(Helper::CALLS).filter_map do |tool|
          next unless tool.is_a?(Hash) && tool["callId"].is_a?(String) && tool["name"].is_a?(String)
          { "callId" => tool["callId"].first(200), "name" => tool["name"].first(64), "status" => tool["status"].to_s.first(16),
            "output" => tool["output"].to_s.last(2_000),
            "arguments" => (tool["arguments"] if tool["arguments"].is_a?(Hash) && tool["arguments"].to_json.bytesize <= 4_000) }.compact
        end
      end
  end
end
