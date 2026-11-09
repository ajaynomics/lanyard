module Sidecar
  # The live reply while a run streams, about five times a second.
  class FramesController < PrivateController
    COMPACTION_TRIGGERS = %w[ manual threshold overflow ].freeze

    def create
      data = request.request_parameters
      raise ActionController::BadRequest unless data["seq"].is_a?(Integer) && [ true, false ].include?(data["busy"])
      conversation.receive_frame(seq: data["seq"], busy: data["busy"], tail: data["tail"].to_s.first(200_000),
        thinking: data["thinking"].to_s.first(200_000), failure: data["failure"], tools: tools(data["tools"]),
        usage: (data["usage"] if data["usage"].is_a?(Hash)), compaction: compaction(data["compaction"]),
        compaction_failed: compaction(data["compactionFailed"]), notes_file: notes_file(data["notesFile"]), sent: sent(data["sent"]),
        queued: (Conversation.queued_from(data["queued"]) if data.key?("queued")))
      head :no_content
    end

    private
      # A summary in the making, or the newest that failed: only what started it.
      def compaction(value)
        value.slice("trigger") if value.is_a?(Hash) && COMPACTION_TRIGGERS.include?(value["trigger"])
      end

      # How much of the reply and the thinking the frame before carried, in bytes.
      def sent(value)
        return unless value.is_a?(Hash) && value.values_at("tail", "thinking").all? { it.is_a?(Integer) && it >= 0 }
        { reply: value["tail"], thinking: value["thinking"] }
      end

      def notes_file(value)
        { "bytes" => value["bytes"] } if value.is_a?(Hash) && value["bytes"].is_a?(Integer) && value["bytes"] >= 0
      end

      # The sidecar sends at most 4 KB of each call's output; a little slack for
      # characters, and a bound on the list, in case it ever sends more. A
      # call's input is shown as sent, unless it is long; a helper's line says
      # how many calls it has made.
      def tools(list)
        Array(list).first(64).filter_map do |tool|
          next unless tool.is_a?(Hash) && tool["callId"].is_a?(String) && tool["callId"].match?(Invocation::CALL_ID) && tool["name"].is_a?(String)
          { "callId" => tool["callId"], "name" => tool["name"].first(64), "status" => tool["status"].to_s, "output" => tool["output"].to_s.last(8_000),
            "arguments" => (tool["arguments"] if tool["arguments"].is_a?(Hash) && tool["arguments"].to_json.bytesize <= 8_000),
            "count" => (tool["count"] if tool["count"].is_a?(Integer)) }.compact
        end
      end
  end
end
