class Tool::CurrentTime < Tool
  description "The current date and time where the person is. With received_since, also what reached you from others since then, " \
    "one row per channel (email, Concourse, Campfire, Telegram, texts), each message with its id: check it before saying nobody has answered, " \
    "and after a summary of earlier messages. With read_received, one of those messages again in full, as it reached you."
  # Folded in here rather than tools of their own: some agents are at the
  # tool limit (issue #43), and an agent's tools are the ones its person picked.
  argument :received_since, :string, required: false, max_length: 64,
    description: "An ISO 8601 time, as YYYY-MM-DDThh:mm:ss±hh:mm: list what you received since then."
  argument :read_received, :integer, required: false,
    description: "The id of a message received_since listed: its whole text, still marked as someone else's where it was."

  def call(received_since: nil, read_received: nil)
    now = Time.current.in_time_zone(agent.time_zone)
    { now: now.iso8601, timeZone: agent.time_zone, weekday: now.strftime("%A"),
      received: (Agent::Received.new(agent, since: since(received_since)).to_h if received_since),
      message: (received(read_received) if read_received) }.compact
  end

  private
    def since(text)
      Time.iso8601(text)
    rescue ArgumentError
      raise Tool::Refusal, "received_since should be an ISO 8601 time, as YYYY-MM-DDThh:mm:ss±hh:mm, not #{text.inspect}."
    end

    # Only what reached this agent's own thread from others; a summary may
    # have taken it from the model's view, never from the thread's copy.
    def received(id)
      message = agent.conversation.messages.find_by(id: id)
      incoming = message&.incoming
      raise Tool::Refusal, "#{id} isn't a message you received. Use an id received_since listed." unless incoming
      { id: message.id, channel: incoming.channel, from: incoming.sender, at: message.created_at.in_time_zone(agent.time_zone).iso8601,
        untrusted: !incoming.trusted, text: message.content.to_s.sub(Conversation::DATE_NOTE, "") }
    end
end
