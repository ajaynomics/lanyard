# Where the `mcp` gem's OAuth client keeps what it learns about one connector:
# the client registration, the tokens and the one sign-in in progress, each in
# an encrypted column on the row (pi keeps the same in mcp-auth.json). The gem
# does the protocol: discovery (RFC 9728, RFC 8414), dynamic registration
# (RFC 7591), PKCE S256, `state`, `resource` (RFC 8707), refresh, and one retry
# after a 401 (for a refresh token good once, through McpServer::Renewal).
#
# Only a person starts a sign-in: away from one (a job, a tool call), a server
# that wants a new sign-in gets SignInNeeded instead of a pending one.
class McpServer::Authorization
  def initialize(server, signing_in: false)
    @server, @signing_in = server, signing_in
  end

  # A renewal of a refresh token good once keeps the tokens it claimed in a
  # storage of its own, and sets up its own requests (McpServer::Renewal).
  def provider(storage: self, http_client_customizer: method(:customize))
    MCP::Client::OAuth::Provider.new(
      client_metadata: McpServer.client_metadata.without(:client_uri, :logo_uri), client_id_metadata_document_url: McpServer.client_metadata_url,
      scope: @server.oauth_scope, redirect_uri: McpServer.redirect_uri, redirect_handler: ->(_url) { }, storage:, http_client_customizer:)
  end

  # The gem's own connection for discovery, the code exchange and renewals:
  # pinned to a public address, and for an app in the vault, its token
  # requests sent only to the host the vault entry is saved for.
  def customize(faraday)
    McpServer::Address.pin(faraday) if @server.pinned?
    McpServer::VaultClient.new(@server).guard(faraday) if @server.vault_app?
  end

  def tokens = @server.oauth_tokens

  # A fresh Gmail sign-in can replace the account even without signing out
  # first (an outside sign-in link). It cannot inherit a conversation grant.
  def save_tokens(tokens, renewing: false)
    @server.ordinary_oauth_write do
      @server.gmail_reply_grants.delete_all if tokens && !renewing && @server.conversation_id? && @server.google == :gmail
      # New tokens end any claim on the old refresh token (McpServer::Renewal); a connector never claimed has none to end.
      @server.update!(oauth_tokens: token_attributes(tokens), refresh_claim: nil, refresh_claimed_at: nil)
    end
  end

  def token_attributes(tokens)
    tokens&.merge("expires_at" => (Time.current.to_i + tokens["expires_in"].to_i if tokens["expires_in"]),
      "signed_in_at" => @server.oauth_tokens&.dig("signed_in_at") || Time.current.to_i)&.compact
  end

  # A registration made for another redirect address (APP__URL changed) is
  # not used; the gem registers again. A pasted client lists none. The
  # person's own client comes before the instance's app. An app in the vault
  # is read once for this sign-in or renewal, bound to the issuer kept for it.
  def client_information
    return (@vault_client ||= McpServer::VaultClient.new(@server).to_h).merge(@server.oauth_client.to_h.slice("issuer")) if @server.vault_app?
    info = @server.oauth_client
    info = nil unless info && Array(info["redirect_uris"]).then { it.empty? || it.include?(McpServer.redirect_uri) }
    info || @server.instance_client
  end

  # Of an app in the vault only the issuer it is bound to is kept, never its ID or secret.
  def save_client_information(info)
    info = info&.slice("issuer").presence if @server.vault_app?
    @server.ordinary_oauth_write { @server.update!(oauth_client: info) }
  end

  def save_pending_authorization(state, pending)
    raise McpServer::SignInNeeded, "#{@server} needs you to sign in again." unless @signing_in
    @server.ordinary_oauth_write { @server.update!(oauth_state: state, oauth_pending: pending) }
  end

  def pending_authorization(state)
    @server.oauth_pending if @server.oauth_state && ActiveSupport::SecurityUtils.secure_compare(@server.oauth_state, state.to_s)
  end

  # Used once: of two callbacks with the same `state`, only one clears it.
  def delete_pending_authorization(state)
    pending = pending_authorization(state)
    cleared = @server.workspace.mcp_servers.where(id: @server.id, oauth_state: state).update_all(oauth_state: nil, oauth_pending: nil)
    @server.oauth_state = @server.oauth_pending = nil
    @server.clear_attribute_changes(%w[ oauth_state oauth_pending ])
    pending if cleared == 1
  end
end
