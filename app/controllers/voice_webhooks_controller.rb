class VoiceWebhooksController < ActionController::API
  wrap_parameters false
  rate_limit to: 60, within: 1.minute

  def create
    config = DurableAssistants.config(:voice)
    return head :not_found unless config&.enabled == true && VoiceOffer::ID.match?(config.project_id.to_s) &&
      config.project_id == config.webhook_project_id

    body = request.body.read(VoiceOffer::MAX_BYTES + 1).to_s
    offer = VoiceOffer.new(body, request.headers)
    return head :bad_request unless offer.signed_with?(config.webhook_secret)

    identity = offer.identity
    unless identity
      Rails.logger.warn("Voice offer refused: #{offer.refusal}")
      return head :unprocessable_content
    end

    agent_id = Integer(config.agent_id.to_s, 10, exception: false)
    agent = Agent.find_by(id: agent_id) if agent_id&.positive? # tenancy-ok: the install binds one signed endpoint to one agent
    # Decided here, from the number, and only the answer kept (Agent::VoiceCall::Reach).
    status = agent ? Agent::VoiceCall.record_offer(agent, identity.merge(reach: Agent::VoiceCall::Reach.of(agent, offer.calling_number))) : :not_found
    return turn_away(identity[:session_id], config, status) unless status == :ok

    call = agent.voice_calls.find_by(session_id: identity[:session_id])
    if call && call.outcome.nil?
      log_offer(call, offer)
      VoiceAnswerJob.perform_later(call)
    end
    head :ok
  end

  private
    def log_offer(call, offer)
      headers = offer.caller_header_presence
      Rails.logger.info("Voice call #{call.id} offer: From=#{presence_of(headers[:from])} P-Asserted-Identity=#{presence_of(headers[:asserted_identity])}")
    end

    def presence_of(header) = header ? "present" : "absent"

    # No offer to answer: decline at once, unless its session waits to be answered.
    def turn_away(session_id, config, status)
      recorded = Agent::VoiceCall.exists?(session_id:) # tenancy-ok: one session ID, install-wide
      DurableAssistants::Live.reject(config.api_key, session_id) if config.api_key.present? && !recorded
    rescue DurableAssistants::Live::Error => error
      Rails.logger.warn("Voice session not rejected: #{error.message}")
    ensure
      head status
    end

    def process_action(...)
      # Rails must not parse or log SIP headers before signature verification.
      request.request_parameters = {}
      super
    end
end
