# A connector: a remote MCP server whose tools a person's agents may use
# (docs/design/PARITY.md §7 and Round 6). Like pi's mcp.json, there are two
# levels: the person's own, which every one of their agents gets, and one
# agent's (conversation_id), which replaces a same-named one of the person's
# or, with no address, only switches it off for that agent.
#
# Rails is the client, through the official `mcp` gem, which also does the MCP
# sign-in (McpServer::Authorization keeps what it learns here, encrypted). A
# refresh lists the server's tools and keeps them, so building a definition
# never waits on the network; each call then goes through the Invocation ledger.
class McpServer < ApplicationRecord
  # Room for `mcp__<name>__` and a readable tool name inside the sidecar's 64.
  NAME = /\A[a-z][a-z0-9_]{0,19}\z/
  LOCAL_HOSTS = %w[ localhost 127.0.0.1 ::1 [::1] ].freeze
  TIMEOUT = 30 # seconds, for each request and any stream the server holds open
  RENEW_BEFORE = 1.minute

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
  encrypts :headers, :oauth_client, :oauth_tokens, :oauth_pending

  # A client the person registered with the service themselves, for one that
  # offers no dynamic registration (Slack, GitHub); pi's `oauth.clientId`.
  attribute :client_id, :string
  attribute :client_secret, :string

  # Both connector pages follow a refresh or a sign-in.
  broadcasts_refreshes_to ->(server) { [ server.user, :connectors ] }

  scope :global, -> { where(conversation_id: nil) }

  normalizes :token, :client_id, :client_secret, with: -> { it.strip.presence }
  validates :name, format: { with: NAME, message: "must start with a letter and use only a-z, 0-9 and _ (up to 20)" },
    uniqueness: { scope: %i[ user_id conversation_id ] }
  validate :url_is_https, if: -> { url.present? || enabled? }
  validate :switches_off_only_for_an_agent, if: -> { url.blank? }
  validate :conversation_is_the_users
  validate :fits_the_agents, if: :tools_changed?

  before_save :keep_own_client, if: :client_id

  # The redirect address registered with every authorization server: one
  # route on this app's public origin (APP__URL).
  def self.redirect_uri
    URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.connectors_callback_path).to_s
  end

  # Lists the server's tools and keeps them, or keeps why it could not. Network
  # work, so it runs in McpServerRefreshJob, never inside a transaction.
  def refresh
    listed = connect { it.tools }.map do
      { "name" => it.name, "description" => it.description.to_s, "input_schema" => it.input_schema || {},
        "annotations" => it.annotations || {} }
    end
    update!(tools: listed, refreshed_at: Time.current, refresh_error: nil)
  rescue Unreachable => problem
    record_problem problem.message
  rescue ActiveRecord::RecordInvalid
    record_problem errors.full_messages.to_sentence
  end

  def refreshing? = url.present? && refreshed_at.nil?

  # One call to one of its tools; the raw JSON-RPC result, for Tool::Mcp to read.
  def call_tool(name, arguments)
    connect { it.call_tool(name: name, arguments: arguments) }.fetch("result") { raise Unreachable, "#{self.name} sent no result." }
  end

  # Its tools, each answering like a Tool class.
  def tool_classes = tools.map { Tool::Mcp.new(self, it) }

  def signed_in? = oauth_tokens.present?

  # Whether to offer "Sign in": no pasted header, no sign-in, and the server refused us.
  def needs_sign_in? = url.present? && !authorized_by_header? && !signed_in? && refresh_error.present?

  # What goes with every request: pi's `headers`, and the token field as a bearer header.
  def request_headers = (headers || {}).merge(token ? { "Authorization" => "Bearer #{token}" } : {})

  # As in pi, OAuth applies only to a server without an Authorization header.
  def authorized_by_header? = request_headers.keys.any? { it.casecmp?("authorization") }

  def signed_in_at = oauth_tokens && Time.zone.at(oauth_tokens["signed_in_at"].to_i)

  # Starts a sign-in: the address of the service's sign-in page to send the
  # person to, or nil when the server let us in without one. The `mcp` gem
  # does the work: the 401, discovery, registration, PKCE and `state`.
  def sign_in_url
    update!(oauth_tokens: nil)
    connect(signing_in: true) { nil }
    nil
  rescue MCP::Client::OAuth::Flow::AuthorizationPendingError => pending
    pending.authorization_url.to_s
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
    update!(oauth_tokens: nil, tools: [], refresh_error: "Signed out.", refreshed_at: Time.current)
  end

  def to_s = name

  private
    def authorization(signing_in: false) = Authorization.new(self, signing_in: signing_in)

    def canonical_url = MCP::Client::OAuth::Discovery.canonicalize_url(url)

    def connect(signing_in: false)
      oauth = authorization(signing_in:).provider if !authorized_by_header? && (signing_in || signed_in?)
      renew(oauth) if oauth && expiring?
      transport = MCP::Client::HTTP.new(url: url, headers: request_headers, oauth: oauth,
        max_reconnection_wait: TIMEOUT) { it.options.timeout = TIMEOUT }
      client = MCP::Client.new(transport: transport)
      # The 2025 handshake every current server speaks; :auto would probe the
      # 2026 discovery first and fall back to this anyway.
      client.connect(client_info: { name: "durable-assistants", version: "1" }, mode: :legacy)
      yield client
    rescue MCP::Client::RequestHandlerError => failure
      raise SignInNeeded, "#{name} needs you to sign in." if failure.error_type == :unauthorized
      raise Unreachable, "Could not reach #{name}: #{failure.message}".truncate(500)
    rescue *FAILURES => failure
      raise Unreachable, "Could not reach #{name}: #{failure.message}".truncate(500)
    ensure
      close transport
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

    def record_problem(message)
      restore_attributes
      update!(refresh_error: message, refreshed_at: Time.current)
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

    # pi's project entry with no address: it only switches the person's connector off for one agent.
    def switches_off_only_for_an_agent
      errors.add(:url, "can't be blank") unless conversation && !enabled?
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
