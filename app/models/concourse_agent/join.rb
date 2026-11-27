# A join in progress ties the browser to the agent and workspace where it
# started. The encrypted session holds the state and PKCE verifier; Concourse
# only gets the state and the verifier's challenge. A pending cache entry
# lets only one callback use that state, even if it gets an older cookie.
class ConcourseAgent::Join
  LIFETIME = 10.minutes

  SESSION_FIELDS = %w[ agent_id workspace_id state verifier started_at ].freeze

  attr_reader :agent_id, :workspace_id, :state, :verifier, :started_at

  def self.start(agent)
    new("agent_id" => agent.id, "workspace_id" => agent.workspace_id, "state" => SecureRandom.urlsafe_base64(32),
      "verifier" => SecureRandom.urlsafe_base64(64), "started_at" => Time.current.to_i)
  end

  def self.from(stored)
    new(stored) if stored.is_a?(Hash) && stored.values_at(*SESSION_FIELDS).all?(&:present?)
  end

  # The one callback every join comes back to, fixed for the install as the
  # connectors' is.
  def self.redirect_uri
    URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.concourse_callback_path).to_s
  end

  def initialize(stored)
    @agent_id, @workspace_id, @state, @verifier, @started_at = stored.values_at(*SESSION_FIELDS)
  end

  def to_h = SESSION_FIELDS.index_with { public_send(it) }

  def remember = Rails.cache.write(cache_key, true, expires_in: LIFETIME)

  # The store deletes atomically; a missing entry cannot authorize a callback.
  def consume = Rails.cache.delete(cache_key)

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

  def matches?(given, workspace:)
    workspace.id == workspace_id && given.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(state, given) &&
      (Time.current.to_i - started_at).between?(0, LIFETIME.to_i)
  end

  # Redeems Concourse's code for the agent's machine client and keeps it, then
  # asks where it stands. The person picks the organization at Concourse, so
  # only now is it known which: a new one adds an identity; one where the
  # agent was declined or disconnected takes its place, keeping its record,
  # tasks and push address; one where it is already on Concourse changes
  # nothing, since a second address there would split its mail. A credential
  # it doesn't keep is retired, so none is left that nobody holds. Outside the
  # workspace's home network it is a bridge, which `joiner` approves if they
  # own the workspace, and its owner otherwise (ConcourseAgent::Bridge).
  def finish(agent, code, joiner:)
    unless agent.id == agent_id && agent.workspace_id == workspace_id
      raise DurableAssistants::Concourse::Client::Error.new("This join no longer matches where it started. Start again.", status: 200)
    end

    grant = DurableAssistants::Concourse::Connect.redeem(code: code.to_s, redirect_uri: self.class.redirect_uri, code_verifier: verifier)
    organization = grant.dig("agent", "organization")
    if (joined = agent.concourse_agents.find_by(organization: organization))&.joined?
      retire(grant)
      raise DurableAssistants::Concourse::Client::Error.new("#{agent} is in #{organization} already, as #{joined.handle}, so nothing changed.", status: 200)
    end
    concourse_agent = begin
      ConcourseAgent.transaction do
        # The agent could have moved, or the joiner lost access, while Concourse answered.
        joiner.agents.lock.find_by!(id: agent_id, workspace_id: workspace_id)
        credential = { handle: grant["path"], client_id: grant["client_id"], client_secret: grant["client_secret"], status: grant.dig("agent", "status") }
        (joined ? replace(joined, credential) : agent.concourse_agents.create!(organization: organization, **credential)).tap do |identity|
          identity.approve_or_ask(joiner)
        end
      end
    rescue ActiveRecord::ActiveRecordError
      retire(grant)
      raise DurableAssistants::Concourse::Client::Error.new("#{agent} joined Concourse but could not be saved here, so it was taken off again. Start again.", status: 200)
    end
    concourse_agent.check
    concourse_agent
  end

  private
    def cache_key = [ "concourse-join", agent_id, workspace_id, Digest::SHA256.hexdigest(state) ]

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
