# The caller's question and its spoken answer share the transcript's sideband.
# Caller ID can be faked: give the question to the thread as untrusted phone
# input, never as a written request with the agent's ordinary authority.
class Agent::VoiceCall::Relay
  TOOL = { type: "function", name: "ask_agent",
    description: "Ask the agent to look something up, and get its answer. This cannot send or change anything.",
    parameters: { type: "object", properties: { question: { type: "string", description: "The caller's question or request, in their words." } },
      required: [ "question" ], additionalProperties: false } }.freeze

  INSTRUCTIONS = "You relay a phone call. For each question or request, call ask_agent once with the caller's words, " \
    "and return its answer as it is. Never call it twice for the same request, and never say something was done unless the answer says so.".freeze

  ANSWER = "They hear the reply that ends your turn, read aloud: a sentence or two, in plain words. " \
    "From a call you can only look things up. If asked to send, book, pay or change something, say it must be asked in writing.".freeze

  # A caller waits in silence; past this, they hear that no answer came.
  WAIT = 20.seconds
  POLL = 0.25
  NO_ANSWER = "I couldn't get an answer in time. The request may still be under way, so don't ask again: " \
    "tell the caller the answer will come in writing.".freeze
  UNAVAILABLE = "I couldn’t ask the agent from this call. Ask in writing.".freeze
  SPOKEN = 2_000

  def self.delegation(model)
    { type: "responses", responses: { model:, instructions: INSTRUCTIONS, tools: [ TOOL ], tool_choice: "auto", parallel_tool_calls: false } }
  end

  def initialize(call, wait: WAIT)
    @call, @wait, @answered = call, wait, Set.new
  end

  # The sideband replays events on attach. Answer each once without holding up the transcript.
  def handle(event, sideband)
    return unless @call.reach_owner?
    item = asked(event)
    return unless item && @answered.add?(item["call_id"])
    sideband.async do
      sideband.write(type: "response.item.create", item: { type: "function_call_output", call_id: item["call_id"], output: answer(item) })
      sideband.write(type: "response.create")
    end
  end

  private
    def asked(event)
      item = event.dig("event", "item") if event["type"] == "response.event" && event.dig("event", "type") == "response.output_item.done"
      item if item.is_a?(Hash) && item["type"] == "function_call" && item["name"] == TOOL[:name] &&
        item["call_id"].is_a?(String) && item["call_id"].bytesize.between?(1, 128)
    end

    def answer(item)
      arguments = JSON.parse(item["arguments"].to_s)
      question = arguments["question"].strip if arguments.is_a?(Hash) && arguments["question"].is_a?(String)
      return UNAVAILABLE if question.blank?

      conversation = @call.agent.conversation
      request_id = "call:#{@call.session_id}:#{item["call_id"]}"
      Async::Task.current.with_timeout(@wait.to_f) do
        receipt = conversation.receive(question, from: Agent::VoiceCall::FROM, via: Agent::VoiceCall::VIA, answer: ANSWER,
          request_id:, when_busy: "reject", phone: true)
        receipt ? reply(conversation, receipt.fetch("id")) : UNAVAILABLE
      end
    rescue Async::TimeoutError
      NO_ANSWER
    rescue JSON::ParserError, Conversation::Submission::Refused, DurableAssistants::PiDurable::Client::Error
      UNAVAILABLE
    end

    def reply(conversation, id)
      client = DurableAssistants::PiDurable::Client.new
      loop do
        receipt = client.phone_reply(conversation.access, conversation.durable_id, id)
        return Message.plain_text(receipt["answer"]).truncate(SPOKEN, separator: /\s/).presence || UNAVAILABLE if receipt["status"] == "done"
        return UNAVAILABLE if receipt["status"] == "unanswered"
        sleep POLL
      end
    end
end
