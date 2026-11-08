# A join in progress (docs/design.md, "Joining Concourse"): what ties the
# person's browser, gone to Concourse to approve, to the agent it comes back
# for. It lives in their session (the encrypted cookie), one at a time, for
# ten minutes, Concourse's own limit for the code: the `state`, so a callback
# this browser did not start finds nothing, and the PKCE verifier, so only
# this install can redeem the code.
class ConcourseAgent::Join
  LIFETIME = 10.minutes

  attr_reader :agent_id, :state, :verifier, :started_at

  def self.start(agent)
    new("agent_id" => agent.id, "state" => SecureRandom.urlsafe_base64(32), "verifier" => SecureRandom.urlsafe_base64(64), "started_at" => Time.current.to_i)
  end

  # The one in the session, if it is one.
  def self.from(stored)
    new(stored) if stored.is_a?(Hash) && stored.values_at("agent_id", "state", "verifier", "started_at").all?(&:present?)
  end

  # The one callback every join comes back to, fixed for the install as the
  # connectors' is.
  def self.redirect_uri
    URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.concourse_callback_path).to_s
  end

  def initialize(stored)
    @agent_id, @state, @verifier, @started_at = stored.values_at("agent_id", "state", "verifier", "started_at")
  end

  def to_h = { "agent_id" => agent_id, "state" => state, "verifier" => verifier, "started_at" => started_at }

  # Where the person's browser goes: Concourse's page, offered the agent's
  # name and a short handle made from it, which they may change there.
  def url(agent)
    DurableAssistants::Concourse::Connect.authorize_url(redirect_uri: self.class.redirect_uri, state: state, handle: self.class.handle_for(agent),
      name: agent.name, code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false))
  end

  # Concourse's rule for a handle: ^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$.
  def self.handle_for(agent)
    agent.name.parameterize.first(40).gsub(/\A-+|-+\z/, "").presence || "agent"
  end

  # The callback is this join's, and in time.
  def matches?(given)
    given.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(state.to_s, given) && Time.current.to_i - started_at.to_i <= LIFETIME
  end

  # Redeems Concourse's code for the agent's machine client and keeps it, in
  # place of a declined or disconnected one, then asks where it stands. A
  # credential it can't keep is retired, so none is left that nobody holds.
  def finish(agent, code)
    grant = DurableAssistants::Concourse::Connect.redeem(code: code.to_s, redirect_uri: self.class.redirect_uri, code_verifier: verifier)
    concourse_agent = begin
      ConcourseAgent.transaction do
        replace(agent.concourse_agent)
        agent.association(:concourse_agent).reset
        agent.create_concourse_agent!(organization: grant.dig("agent", "organization"), handle: grant["path"],
          client_id: grant["client_id"], client_secret: grant["client_secret"], status: grant.dig("agent", "status"))
      end
    rescue ActiveRecord::ActiveRecordError
      DurableAssistants::Concourse::Client.retire(client_id: grant["client_id"], client_secret: grant["client_secret"], address: grant.dig("agent", "address"))
      raise DurableAssistants::Concourse::Client::Error.new("#{agent} joined Concourse but could not be saved here, so it was taken off again. Start again.", status: 200)
    end
    concourse_agent.check
    concourse_agent
  end

  private
    # A declined agent, or one still waiting, is retired on Concourse before
    # it is forgotten; a disconnected one is retired already.
    def replace(old)
      return unless old
      DurableAssistants::Concourse::Client.retire(client_id: old.client_id, client_secret: old.client_secret, address: old.to_s) if old.declined? || old.awaiting_approval?
      old.destroy!
    end
end
