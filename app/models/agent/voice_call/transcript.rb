# What was said on a call, from its sideband's transcript deltas
# (docs/phone.md, "After a call"). Fragments carry their own spaces, so they
# are joined as they are, in their order on the call's timeline; the 3
# seconds replayed on attaching are told apart by event_id.
class Agent::VoiceCall::Transcript
  SPEAKERS = { "session.input_transcript.delta" => :caller, "session.output_transcript.delta" => :agent }.freeze
  REASON = /\A[a-z_]{1,40}\z/

  # Why the call ended, once session.closed has said; nil until then.
  attr_reader :closed

  def initialize
    @fragments, @seen = [], Set.new
  end

  def <<(event)
    return self if event["event_id"] && !@seen.add?(event["event_id"])
    if (speaker = SPEAKERS[event["type"]])
      @fragments << Fragment.new(event["start_ms"].to_i, @fragments.size, speaker, event["delta"].to_s)
    elsif event["type"] == "session.closed"
      @closed = REASON.match?(event["reason"].to_s) ? event["reason"] : "unknown"
    end
    self
  end

  def empty? = turns.empty?

  # One line per turn: "Caller: ..." or the agent's name.
  def lines(agent_name)
    turns.map { |speaker, words| "#{speaker == :caller ? "Caller" : agent_name}: #{words}" }.join("\n")
  end

  private
    Fragment = Data.define(:at, :order, :speaker, :words)

    def turns
      @fragments.sort_by { [ it.at, it.order ] }.chunk(&:speaker)
        .map { |speaker, fragments| [ speaker, fragments.sum("", &:words).strip ] }
        .reject { |_, words| words.empty? }
    end
end
