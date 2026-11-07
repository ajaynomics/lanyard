# A connector: an MCP server whose tools a person's agents may use
# (docs/design/PARITY.md §7, Rounds 6 and 7). A remote one has a `url`; pi's
# `command` entry runs on each agent's own computer instead, never here.
# Like pi's mcp.json, there are two levels: the person's own, which every one
# of their agents gets, and one agent's (conversation_id), which replaces a
# same-named one of the person's or, with no address, only switches it off for
# that agent.
#
# Rails is the client, through the official `mcp` gem, which also does the MCP
# sign-in (McpServer::Authorization keeps what it learns here, encrypted). A
# refresh lists the server's tools and keeps them, so building a definition
# never waits on the network; each call then goes through the Invocation ledger.
# A command connector is reached through the sidecar (CommandTransport), on
# the computer of the agent it serves.
class McpServer < ApplicationRecord
  # Room for `mcp__<name>__` and a readable tool name inside the sidecar's 64.
  NAME = /\A[a-z][a-z0-9_]{0,19}\z/
  LOCAL_HOSTS = %w[ localhost 127.0.0.1 ::1 [::1] ].freeze
  TIMEOUT = 30 # seconds, for each request and any stream the server holds open
  RENEW_BEFORE = 1.minute
  # Google issues a refresh token only to a sign-in that asks for offline
  # access with consent. The `mcp` gem has no setting for extra authorization
  # parameters, so they are added to the address it hands us.
  AUTHORIZATION_PARAMS = { "accounts.google.com" => { "access_type" => "offline", "prompt" => "consent" } }.freeze

  # Anything the server or the wire can go wrong with, as one plain message.
  class Unreachable < StandardError; end
  # The server wants a person to sign in, which only a person can start.
  class SignInNeeded < Unreachable; end
  FAILURES = [ MCP::Client::RequestHandlerError, MCP::Client::ServerError, MCP::Client::ValidationError,
               MCP::Client::PaginationLimitError, MCP::Client::InputRequiredError, MCP::Client::OAuth::Flow::AuthorizationError,
               Faraday::Error, JSON::ParserError ].freeze

  # Emptied by 20261107150000 and dropped by a later migration.
  self.ignored_columns += %w[ bot_id ]

  belongs_to :user
  belongs_to :conversation, optional: true
  encrypts :token
  serialize :headers, coder: JSON
  serialize :oauth_client, coder: JSON
  serialize :oauth_tokens, coder: JSON
  serialize :oauth_pending, coder: JSON
  serialize :env, coder: JSON
  encrypts :headers, :oauth_client, :oauth_tokens, :oauth_pending, :env

  # A client the person registered with the service themselves, for one that
  # offers no dynamic registration (Slack, GitHub); pi's `oauth.clientId`.
  attribute :client_id, :string
  attribute :client_secret, :string

  # Both Connectors pages, and each agent's page for its Connectors button,
  # follow a change a person can see. A token renewed before a call is not one.
  after_commit :broadcast_change, unless: -> { !destroyed? && saved_changes.except("oauth_tokens", "updated_at").none? }

  scope :global, -> { where(conversation_id: nil) }

  normalizes :token, :client_id, :client_secret, :command, :cwd, with: -> { it.strip.presence }
  validates :name, format: { with: NAME, message: "must start with a letter and use only a-z, 0-9 and _ (up to 20)" },
    uniqueness: { scope: %i[ user_id conversation_id ] }
  validate :url_is_https, if: -> { url.present? || (enabled? && !command?) }
  validate :switches_off_only_for_an_agent, if: :switch_off?
  validate :url_or_command
  validate :conversation_is_the_users
  validate :app_is_the_gallerys, if: :oauth_app
  validate :fits_the_agents, if: :tools_changed?

  before_save :keep_own_client, if: :client_id

  # The redirect address registered with every authorization server: one
  # route on this app's public origin (APP__URL).
  def self.redirect_uri
    URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.connectors_callback_path).to_s
  end

  # A gallery entry (config/connectors.yml) as a connector's attributes.
  def self.gallery_attributes(key)
    entry = DurableAssistants.config(:connectors, :gallery, key.to_s.to_sym) or raise ActiveRecord::RecordNotFound, "No gallery entry #{key}"
    { url: entry[:url], oauth_scope: entry[:scope], oauth_app: entry[:app] }.compact
  end

  # Whether this instance has the named OAuth app (PARITY.md §33a).
  def self.instance_app?(name) = DurableAssistants.config(:connectors, :apps, name.to_s.to_sym, :client_id).present?

  # Lists the server's tools and keeps them, or keeps why it could not. Network
  # work, so it runs in McpServerRefreshJob, never inside a transaction. A
  # command connector runs on an agent's computer: its own agent's, or for a
  # person's connector, the agent the refresh was asked from.
  def refresh(agent = conversation)
    listed = connect(agent:) { it.tools }.map do
      { "name" => it.name, "description" => it.description.to_s, "input_schema" => it.input_schema || {},
        "annotations" => it.annotations || {} }
    end
    update!(tools: listed, refreshed_at: Time.current, refresh_error: nil, sign_in_needed: false)
  rescue Unreachable => problem
    record_problem problem.message, sign_in: problem.is_a?(SignInNeeded), refreshed_at: Time.current
  rescue ActiveRecord::RecordInvalid
    record_problem errors.full_messages.to_sentence, refreshed_at: Time.current
  end

  def refreshing? = !switch_off? && refreshed_at.nil?

  # One call to one of its tools for an agent; the raw JSON-RPC result, for
  # Tool::Mcp to read. A call that fails says so on the connector, and one
  # that succeeds clears a failure that is no longer true.
  def call_tool(name, arguments, agent: conversation)
    result = connect(agent:) { it.call_tool(name: name, arguments: arguments) }.fetch("result") { raise Unreachable, "#{self.name} sent no result." }
    update!(refresh_error: nil, sign_in_needed: false) if refresh_error || sign_in_needed?
    result
  rescue Unreachable => problem
    record_problem problem.message, sign_in: problem.is_a?(SignInNeeded)
    raise
  end

  # Pi's /mcp states, in this app's words (PARITY.md Round 8). `refresh_error`
  # is why the last refresh or call failed. With an agent, a command
  # connector it cannot run says so.
  def status(agent = nil)
    if !enabled? then "off"
    elsif agent && !usable_by?(agent) then "no_computer"
    elsif needs_sign_in? then "needs_sign_in"
    elsif refresh_error.present? then "failing"
    elsif refreshing? then "listing"
    else "ok"
    end
  end

  def needs_attention?(agent = nil) = status(agent).in?(%w[ needs_sign_in failing ])

  def command? = command.present?

  # pi's project entry with no address: it only switches the person's connector off for one agent.
  def switch_off? = url.blank? && !command?

  # A command connector runs only on a computer, so an agent without one that is on gets none of its tools.
  def usable_by?(agent) = !command? || agent.bot.computer&.on? == true

  # What the sidecar starts on the agent's computer: pi's entry.
  def launch = { command: command, args: args, env: env || {}, cwd: cwd }

  # Its tools, each answering like a Tool class.
  def tool_classes = tools.map { Tool::Mcp.new(self, it) }

  def signed_in? = oauth_tokens.present?

  # No pasted header, no sign-in, and the server asked for one (sign_in_needed), the
  # person started one and did not finish it, or the connector was set up to sign
  # in (an instance app, a scope or a client): Google lists its tools to anyone and
  # refuses only when one is called, so a 401 alone would not tell us.
  def needs_sign_in? = url.present? && !authorized_by_header? && !signed_in? &&
    (sign_in_needed? || oauth_state.present? || signs_in?)

  def signs_in? = oauth_app.present? || oauth_scope.present? || oauth_client.present?

  # What goes with every request: pi's `headers`, and the token field as a bearer header.
  def request_headers = (headers || {}).merge(token ? { "Authorization" => "Bearer #{token}" } : {})

  # As in pi, OAuth applies only to a server without an Authorization header.
  def authorized_by_header? = request_headers.keys.any? { it.casecmp?("authorization") }

  def signed_in_at = oauth_tokens && Time.zone.at(oauth_tokens["signed_in_at"].to_i)

  # The instance's own app, for a connector made from a gallery entry that
  # names one. Read from settings on each use; the row keeps only the name.
  def instance_client
    app = DurableAssistants.config(:connectors, :apps, oauth_app.to_sym) if oauth_app
    return unless app && app[:client_id].present?
    { "client_id" => app[:client_id], "client_secret" => app[:client_secret].presence,
      "token_endpoint_auth_method" => app[:client_secret].present? ? "client_secret_post" : "none" }.compact
  end

  # Starts a sign-in: the address of the service's sign-in page to send the
  # person to, or nil when the server let us in without one. The `mcp` gem
  # does the work: the 401, discovery, registration, PKCE and `state`.
  def sign_in_url
    update!(oauth_tokens: nil)
    connect(signing_in: true) { nil }
    started_without_a_challenge if signs_in?
  rescue MCP::Client::OAuth::Flow::AuthorizationPendingError => pending
    with_authorization_params(pending.authorization_url)
  end

  # A server that lists its tools without a 401 gives the gem nothing to start
  # from, so a connector set up to sign in starts from the server's published
  # metadata instead, as it would after a challenge.
  def started_without_a_challenge
    flow = MCP::Client::OAuth::Flow.new(provider: authorization(signing_in: true).provider)
    with_authorization_params(flow.authorization_url) if flow.run!(server_url: canonical_url, scope: oauth_scope.presence) == :redirect
  end

  # Completes the sign-in with the service's redirect back to us.
  def finish_sign_in(callback_params)
    MCP::Client::OAuth::Flow.new(provider: authorization.provider)
      .finish!(server_url: canonical_url, callback_params: callback_params.to_h)
  rescue MCP::Client::OAuth::Flow::AuthorizationError => problem
    raise Unreachable, "Could not sign in to #{name}: #{problem.message}".truncate(500)
  end

  # Forgets the tokens, as pi's logout does. The registration stays for the next sign-in.
  def sign_out
    update!(oauth_tokens: nil, tools: [], refresh_error: "Signed out.", sign_in_needed: true, refreshed_at: Time.current)
  end

  def to_s = name

  private
    def authorization(signing_in: false) = Authorization.new(self, signing_in: signing_in)

    def canonical_url = MCP::Client::OAuth::Discovery.canonicalize_url(url)

    def connect(signing_in: false, agent: conversation)
      transport = command? ? CommandTransport.new(self, agent) : http_transport(signing_in)
      client = MCP::Client.new(transport: transport)
      # The 2025 handshake every current server speaks; :auto would probe the
      # 2026 discovery first and fall back to this anyway.
      client.connect(client_info: { name: "durable-assistants", version: "1" }, mode: :legacy)
      yield client
    rescue MCP::Client::RequestHandlerError => failure
      raise Unreachable, "#{name} refused its Authorization header." if failure.error_type == :unauthorized && authorized_by_header?
      raise SignInNeeded, "#{name} needs you to sign in." if failure.error_type == :unauthorized
      raise Unreachable, "Could not reach #{name}: #{failure.message}".truncate(500)
    rescue *FAILURES => failure
      raise Unreachable, "Could not reach #{name}: #{failure.message}".truncate(500)
    ensure
      close transport
    end

    def http_transport(signing_in)
      oauth = authorization(signing_in:).provider if !authorized_by_header? && (signing_in || signed_in?)
      renew(oauth) if oauth && expiring?
      MCP::Client::HTTP.new(url: url, headers: request_headers, oauth: oauth,
        max_reconnection_wait: TIMEOUT) { it.options.timeout = TIMEOUT }
    end

    def expiring?
      expires_at = oauth_tokens&.dig("expires_at")
      expires_at.present? && oauth_tokens["refresh_token"].present? && Time.zone.at(expires_at) < RENEW_BEFORE.from_now
    end

    # Renews a token about to expire. If that fails, the call meets a 401, and
    # the gem refreshes once more or the person is asked to sign in again.
    def renew(oauth)
      MCP::Client::OAuth::Flow.new(provider: oauth).refresh!(server_url: canonical_url)
    rescue MCP::Client::OAuth::Flow::AuthorizationError
      nil
    end

    # Ending the session is a courtesy; a server that refuses it changes nothing here.
    def close(transport)
      transport&.close
    rescue *FAILURES
      nil
    end

    # A server that wants a sign-in has refused any tokens we hold, so they are
    # forgotten: the connector says "needs sign-in" however it was found out.
    def record_problem(message, sign_in: false, **changes)
      restore_attributes
      update!(refresh_error: message, sign_in_needed: sign_in, **changes, **(sign_in ? { oauth_tokens: nil } : {}))
    end

    def broadcast_change = broadcast_refresh_later_to(user, :connectors)

    def with_authorization_params(url)
      uri = URI(url.to_s)
      extra = AUTHORIZATION_PARAMS.fetch(uri.host, {})
      params = URI.decode_www_form(uri.query.to_s).to_h
      uri.query = URI.encode_www_form(extra.merge(params)) if extra.any?
      uri.to_s
    end

    def keep_own_client
      self.oauth_client = { "client_id" => client_id, "client_secret" => client_secret,
        "token_endpoint_auth_method" => client_secret ? "client_secret_post" : "none" }.compact
    end

    # The token goes in a header, so plain http is allowed only to this machine.
    def url_is_https
      uri = URI.parse(url.to_s)
      return if uri.is_a?(URI::HTTPS) && uri.host.present?
      return if uri.is_a?(URI::HTTP) && LOCAL_HOSTS.include?(uri.host)
      errors.add(:url, "must start with https://")
    rescue URI::InvalidURIError
      errors.add(:url, "is not a web address")
    end

    # The instance's secret goes only to the server its gallery entry names.
    def app_is_the_gallerys
      urls = DurableAssistants.config(:connectors, :gallery, default: {}).values.select { it[:app] == oauth_app }.pluck(:url)
      errors.add(:base, "Only a gallery connector can use this instance's #{oauth_app} app") unless urls.include?(url)
    end

    def switches_off_only_for_an_agent
      errors.add(:url, "can't be blank") unless conversation && !enabled?
    end

    def url_or_command
      errors.add(:base, "Give a web address or a command, not both") if url.present? && command?
    end

    def conversation_is_the_users
      errors.add(:conversation, "is not yours") if conversation && conversation.user_id != user_id
    end

    # The sidecar refuses a definition with more than its limit of tools.
    def fits_the_agents
      bots = conversation ? [ conversation.bot ] : user.bots
      connectors = conversation ? conversation.connectors : user.mcp_servers.global
      bots.each do |bot|
        others = bot.tool_names.size + connectors.reject { it == self || it.name == name }.sum { it.tools.size }
        if others + tools.size > Bot::TOOL_LIMIT
          errors.add(:base, "#{name} offers #{tools.size} tools; #{bot} can have #{Bot::TOOL_LIMIT} in all and already has #{others}")
        end
      end
    end
end
