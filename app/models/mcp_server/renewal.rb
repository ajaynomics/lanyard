# Renews the access token of a connector whose refresh token is good once
# (`rotating_refresh` in config/connectors.yml: Slack's), before it expires
# or after the server turns it away (HttpTransport). Any other connector
# renews as the `mcp` gem does (McpServer#renew).
#
# It never holds the database while the service answers: SQLite has one
# writer, so a transaction open across that request would stop every write
# in the app. A short transaction claims the refresh token (its digest, never
# the token), the request goes out with none open, and a second short one
# saves the new tokens only if the row still holds the token claimed, so a
# late answer never overwrites newer ones.
#
# Such a token is spent once used, and no such service promises that sending
# it twice is safe, so a claimed token is never sent again. A call that finds
# it claimed uses the access token while it lasts,
# then is told to try again (Renewing) while the renewal may still be under
# way. The claim is let go only when the token is known never to have left: a
# failure before the token request, or one that never connected. Otherwise
# (no answer in time, a cut connection, an error) nobody can know whether
# the service spent it, so the claim stays and, once the access token can no
# longer be used, every call is asked to sign in again (docs/connectors.md,
# "Sign-in"). An expired token is never sent.
class McpServer::Renewal
  # Seconds to connect, and to read, for each request of a renewal. Left to
  # the library, each waits a minute (Net::HTTP's default).
  TIMEOUT = 10

  # Longer than a renewal can take: a vault read (DurableAssistants::Passbolt::TIMEOUT),
  # then discovery, metadata and the token, each bounded by TIMEOUT to connect and to read.
  # A claim older than this, or one whose renewal ended without knowing, is no longer under way.
  CLAIM_LASTS = 2.minutes

  # Faraday middleware on the renewal's own requests: notes when the refresh
  # token leaves, and when its request failed before a byte was written.
  class Sending < Faraday::Middleware
    UNSENT = [ Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
               Net::OpenTimeout, SocketError, McpServer::Address::Refused ].freeze

    def initialize(app, renewal)
      super(app)
      @renewal = renewal
    end

    def call(env)
      return @app.call(env) unless env.body.to_s.include?("grant_type=refresh_token")
      @renewal.sent = true
      @app.call(env)
    rescue => failure
      @renewal.sent = false if unsent?(failure)
      raise
    end

    private
      def unsent?(failure) = failure.present? && (UNSENT.any? { failure.is_a?(it) } || unsent?(failure.cause))
  end

  # The `mcp` gem's storage for this one refresh: the tokens claimed, and the
  # new ones it hands back to be saved here. The rest is the connector's.
  attr_reader :tokens
  attr_writer :sent
  delegate :client_information, :save_client_information, :save_pending_authorization,
    :pending_authorization, :delete_pending_authorization, to: :@authorization

  def initialize(server)
    @server = server
    @authorization = McpServer::Authorization.new(server)
  end

  # True when the connector holds an access token to send. `rejected` is one
  # the server just refused, which is renewed even before it expires.
  def renew(rejected: nil)
    refresh if claim(rejected)
    return true if usable?(rejected)
    raise McpServer::SignInNeeded, "#{@server.name} needs you to sign in again." if claimed? && !under_way?
    raise McpServer::Renewing, "#{@server.name}'s sign-in is being renewed; try again in a few seconds."
  end

  def save_tokens(tokens) = @renewed = tokens

  private
    # Under the row's lock, which reloads it: whether another call renewed it
    # already or is renewing it now is read from the database, not memory.
    def claim(rejected)
      @server.with_lock do
        next unless due?(rejected) && !claimed?
        @tokens, @claim = @server.oauth_tokens, digest(@server.oauth_tokens)
        @server.update!(refresh_claim: @claim, refresh_claimed_at: Time.current)
      end
    end

    def due?(rejected) = @server.expiring? || (rejected.present? && rejected == access_token && @server.oauth_tokens["refresh_token"].present?)

    def usable?(rejected) = access_token.present? && access_token != rejected && !@server.expired?

    def claimed? = @server.refresh_claim == digest(@server.oauth_tokens)

    def under_way? = @server.refresh_claimed_at&.after?(CLAIM_LASTS.ago)

    def access_token = @server.oauth_tokens&.dig("access_token")

    def refresh
      MCP::Client::OAuth::Flow.new(provider: @authorization.provider(storage: self, http_client_customizer: method(:watch)))
        .refresh!(server_url: MCP::Client::OAuth::Discovery.canonicalize_url(@server.url))
      settle(refresh_claim: nil, refresh_claimed_at: nil, oauth_tokens: @authorization.token_attributes(@renewed))
    rescue MCP::Client::OAuth::Flow::InvalidGrantError
      raise McpServer::SignInNeeded, "#{@server.name} needs you to sign in again." if digest(@server.reload.oauth_tokens) == @claim
    rescue MCP::Client::OAuth::Flow::AuthorizationError, Faraday::Error
      @sent ? settle(refresh_claimed_at: nil) : settle(refresh_claim: nil, refresh_claimed_at: nil)
    rescue McpServer::Unreachable
      # The app's vault is read before anything is sent, so the token is unspent.
      settle(refresh_claim: nil, refresh_claimed_at: nil)
      raise
    end

    # Only while the row still holds the token claimed: a newer sign-in or renewal wins.
    def settle(**changes)
      @server.with_lock do
        @server.update!(**changes) if digest(@server.oauth_tokens) == @claim
      end
    end

    def digest(tokens) = Digest::SHA256.hexdigest(tokens&.dig("refresh_token").to_s)

    # Pinned, and a vault app's token request held to its vault entry's host, as
    # any sign-in's (McpServer::Authorization#customize), before Sending sees it leave.
    def watch(faraday)
      faraday.options.open_timeout = faraday.options.timeout = TIMEOUT
      @authorization.customize(faraday)
      faraday.use Sending, self
    end
end
