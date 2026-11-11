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

  # Redeems Concourse's code for the agent's machine client and keeps it, then
  # asks where it stands. The person picks the organization at Concourse, so
  # only now is it known which: a new one adds an identity; one where the
  # agent was declined or disconnected takes its place, keeping its record,
  # tasks and push address; one where it is already on Concourse changes
  # nothing, since a second address there would split its mail. A credential
  # it doesn't keep is retired, so none is left that nobody holds.
  def finish(agent, code)
    grant = DurableAssistants::Concourse::Connect.redeem(code: code.to_s, redirect_uri: self.class.redirect_uri, code_verifier: verifier)
    organization = grant.dig("agent", "organization")
    if (joined = agent.concourse_agents.find_by(organization: organization))&.joined?
      retire(grant)
      raise DurableAssistants::Concourse::Client::Error.new("#{agent} is in #{organization} already, as #{joined.handle}, so nothing changed.", status: 200)
    end
    concourse_agent = begin
      ConcourseAgent.transaction do
        credential = { handle: grant["path"], client_id: grant["client_id"], client_secret: grant["client_secret"], status: grant.dig("agent", "status") }
        joined ? replace(joined, credential) : agent.concourse_agents.create!(organization: organization, **credential)
      end
    rescue ActiveRecord::ActiveRecordError
      retire(grant)
      raise DurableAssistants::Concourse::Client::Error.new("#{agent} joined Concourse but could not be saved here, so it was taken off again. Start again.", status: 200)
    end
    concourse_agent.check
    concourse_agent
  end

  private
    # A declined agent is retired on Concourse before its credential is
    # forgotten; a disconnected one is retired already. Where it had read to
    # and its push belonged to the old credential.
    def replace(old, credential)
      DurableAssistants::Concourse::Client.retire(client_id: old.client_id, client_secret: old.client_secret, address: old.to_s) if old.declined?
      old.update!(**credential, cursor: nil, push_token: nil, checked_at: nil, check_error: nil)
      old
    end

    def retire(grant)
      DurableAssistants::Concourse::Client.retire(client_id: grant["client_id"], client_secret: grant["client_secret"], address: grant.dig("agent", "address"))
    end
end
