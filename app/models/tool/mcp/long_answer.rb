# A connector's answer longer than the sidecar keeps of one result
# (DurableAssistants::ResultBytes, counted in bytes) is never just lost.
# On the agent's computer (Agent#saves_files?) the whole of it is held for the sidecar to
# save on the agent's computer as a file (Invocation#hold_file,
# agent/files.mjs), and the model reads its start, where the rest is, and that
# it is there. Elsewhere there is nowhere to put the rest, so it is cut, and
# the answer says so.
class Tool::Mcp::LongAnswer
  def initialize(invocation, name)
    @invocation, @name = invocation, name
  end

  # The answer as the model reads it: text alone, or a server's structured
  # content, as JSON, when that is what is too long. A saved answer is listed
  # in found_files, beside any files the answer carried (Tool::Mcp::FoundFile).
  def fit(answer)
    plain = answer.keys == [ :text ]
    whole = plain ? answer[:text].to_s : JSON.generate(answer)
    return answer if DurableAssistants::ResultBytes.of(answer) <= DurableAssistants::ResultBytes::ANSWER
    shown = { text: DurableAssistants::ResultBytes.head(whole, Tool::Mcp::SHOWN_BYTES), truncated: true }
    of = "This answer is cut to the first #{count(shown[:text].length)} of its #{count(whole.length)} characters"
    return shown.merge(note: "#{of}: this agent has no computer of this app's to save the rest on.") unless @invocation.agent.saves_files?

    name = DurableAssistants::Google.safe_name("#{@name}-answer.#{plain ? 'txt' : 'json'}")
    type = plain ? "text/plain" : "application/json"
    held = @invocation.hold_file(io: StringIO.new(whole), filename: name, content_type: type)
    shown.merge(found_files: [ { name: name, type: type, size: whole.bytesize, held: held } ],
      note: "#{of}; the whole answer is saved on your computer, in #{name}'s saved path in found_files. Read on there.")
  end

  private
    def count(number) = ActiveSupport::NumberHelper.number_to_delimited(number)
end
