class Agent::VoiceCall < ApplicationRecord
  belongs_to :agent

  # Whose call it is, as far as the agent goes (Reach): never the number.
  enum :reach, %w[ stranger owner ].index_by(&:itself), prefix: true

  def self.record_offer(agent, offer)
    delivery_id, event_id, session_id, body_digest = offer.values_at(:delivery_id, :event_id, :session_id, :body_digest)
    # SQLite's immediate transaction keeps replay claims atomic across agent rebinds.
    transaction do
      matches = where(delivery_id:).or(where(event_id:)).or(where(session_id:)).to_a
      if matches.empty?
        agent.voice_calls.create!(offer)
      elsif matches.any? { |receipt| receipt.body_digest != body_digest }
        next :conflict
      elsif matches.none? { |receipt| receipt.delivery_id == delivery_id }
        # Claim the fresh delivery ID without attaching it to another agent.
        insert!({ delivery_id:, body_digest: })
      end
      :ok
    end
  end

  # Claimed before OpenAI is asked, so a replay or a second run never asks
  # twice; an answer that may have reached OpenAI stays "unknown".
  def answer(config)
    return unless self.class.where(id:, outcome: nil).update_all(outcome: "answering", updated_at: Time.current) == 1

    if agent
      backend = relay_model(config)
      DurableAssistants::Live.accept(config.api_key, session_id, model: config.model,
        instructions: Agent::VoicePrompt.new(agent, reach:, relay: backend.present?).to_s, delegation: (Relay.delegation(backend) if backend))
      update!(outcome: "accepted")
    else
      DurableAssistants::Live.reject(config.api_key, session_id)
      update!(outcome: "rejected")
    end
  rescue DurableAssistants::Live::Error => error
    update!(outcome: error.is_a?(DurableAssistants::Live::Unknown) ? "unknown" : "failed")
    raise
  end

  VIA = "Phone call".freeze
  # The caller's number is never kept (Reach), so the thread names no one.
  FROM = "your phone line's caller".freeze
  SUMMARY = "The call has ended and the caller can't hear you. Reply here with a summary of the call in three lines.".freeze
  CUT_SHORT = "the connection to the call closed before the call ended".freeze

  # Follows an accepted call until it ends, then hands what was said, or why
  # nothing was, to this call's own agent's thread (docs/phone.md, "After a
  # call"). Nothing is guessed: a missing transcript says so and why.
  def listen(config)
    return unless outcome == "accepted" && agent

    transcript, relay, lost = Transcript.new, (Relay.new(self) if relay_model(config)), nil
    begin
      stream = DurableAssistants::Live.attach(config.api_key, session_id, call_id: id) do |event, sideband|
        transcript << event
        relay&.handle(event, sideband)
      end
      lost = "the call's event stream was interrupted" if stream == :reattached
    rescue DurableAssistants::Live::Error => error
      lost = error.message
    end
    receipt = agent.conversation.receive(report(transcript, lost), from: FROM, via: VIA, answer: SUMMARY, request_id: "voice-call:#{id}", phone: true)
    Rails.logger.info("Voice call #{id} transcript hand-off: #{receipt ? 'submitted' : 'held'} text=#{transcript.empty? ? 'unavailable' : 'captured'}")
  end

  private
    def relay_model(config) = (config.backend_model.presence if reach_owner?)

    def report(transcript, lost)
      ended = transcript.closed
      if transcript.empty?
        "Transcript unavailable: #{lost || (ended ? "nothing was transcribed before the call ended (#{ended})" : "#{CUT_SHORT}, and nothing was transcribed")}."
      elsif lost || !ended
        "This transcript may be incomplete: #{lost || CUT_SHORT}.\n\n#{transcript.lines(agent.name)}"
      else
        transcript.lines(agent.name)
      end
    end
end
