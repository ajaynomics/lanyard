# Where the `mcp` gem's OAuth client keeps what it learns about one connector:
# the client registration, the tokens and the one sign-in in progress, each in
# an encrypted column on the row (pi keeps the same in mcp-auth.json). The gem
# does the protocol: discovery (RFC 9728, RFC 8414), dynamic registration
# (RFC 7591), PKCE S256, `state`, `resource` (RFC 8707), refresh, and one retry
# after a 401.
#
# Only a person starts a sign-in: away from one (a job, a tool call), a server
# that wants a new sign-in gets SignInNeeded instead of a pending one.
class McpServer::Authorization
  def initialize(server, signing_in: false)
    @server, @signing_in = server, signing_in
  end

  def provider
    redirect_uri = McpServer.redirect_uri
    MCP::Client::OAuth::Provider.new(
      client_metadata: { client_name: DurableAssistants.config(:app, :name), redirect_uris: [ redirect_uri ],
        grant_types: %w[ authorization_code refresh_token ], response_types: %w[ code ], token_endpoint_auth_method: "none" },
      scope: @server.oauth_scope, redirect_uri: redirect_uri, redirect_handler: ->(_url) { }, storage: self)
  end

  def tokens = @server.oauth_tokens

  # With when they expire and when the person signed in, for the page.
  def save_tokens(tokens)
    tokens &&= tokens.merge("expires_at" => (Time.current.to_i + tokens["expires_in"].to_i if tokens["expires_in"]),
      "signed_in_at" => @server.oauth_tokens&.dig("signed_in_at") || Time.current.to_i).compact
    @server.update!(oauth_tokens: tokens)
  end

  # A registration made for another redirect address (APP__URL changed) is
  # not used; the gem registers again. A pasted client lists none. The
  # person's own client comes before the instance's app.
  def client_information
    info = @server.oauth_client
    info = nil unless info && Array(info["redirect_uris"]).then { it.empty? || it.include?(McpServer.redirect_uri) }
    info || @server.instance_client
  end

  def save_client_information(info) = @server.update!(oauth_client: info)

  def save_pending_authorization(state, pending)
    raise McpServer::SignInNeeded, "#{@server} needs you to sign in again." unless @signing_in
    @server.update!(oauth_state: state, oauth_pending: pending)
  end

  def pending_authorization(state)
    @server.oauth_pending if @server.oauth_state && ActiveSupport::SecurityUtils.secure_compare(@server.oauth_state, state.to_s)
  end

  # Used once: of two callbacks with the same `state`, only one clears it.
  def delete_pending_authorization(state)
    pending = pending_authorization(state)
    cleared = @server.user.mcp_servers.where(id: @server.id, oauth_state: state).update_all(oauth_state: nil, oauth_pending: nil)
    @server.oauth_state = @server.oauth_pending = nil
    @server.clear_attribute_changes(%w[ oauth_state oauth_pending ])
    pending if cleared == 1
  end
end
