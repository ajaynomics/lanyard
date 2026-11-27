# The OAuth app of a connector whose gallery entry says `vault: true`: its
# client ID and secret are the username and password of the vault entry the
# connector names (vault_entry), read as its agent or its workspace, on that
# workspace's own server if it has one (DurableAssistants::Passbolt), for
# each use and never kept. The entry must be saved for the entry's
# vault_host, where the secret goes, or the secret is not sent there.
class McpServer::VaultClient
  # The `mcp` gem posts the secret to whatever token address the service's
  # sign-in metadata names, so every OAuth request it makes for such a
  # connector passes through here: a token request (it carries grant_type)
  # goes only to https://vault_host, the host the vault entry is saved for,
  # or nothing is sent. That covers the code exchange, each renewal and the
  # gem's own refresh after a 401.
  class TokenAddress < Faraday::Middleware
    def initialize(app, server, host)
      super(app)
      @server, @host = server, host
    end

    def on_request(env)
      return unless Rack::Utils.parse_query(env.body.to_s).key?("grant_type")
      return if env.url.scheme == "https" && env.url.host == @host && env.url.port == 443
      raise McpServer::Unreachable,
        "#{@server.name}'s sign-in server named a token address its vault entry isn't for (#{env.url.host}, not #{@host}), so nothing was sent."
    end
  end

  def initialize(server)
    @server = server
  end

  def to_h
    entry = DurableAssistants::Passbolt.sign_in_by_name(@server.conversation&.agent || @server.workspace, name)
    raise McpServer::Unreachable, "#{name} is saved for #{entry.host || "no address"}, not #{host}, so it is not sent there." unless host && entry.host == host
    raise McpServer::Unreachable, "#{name} needs the app's client ID as its username and its secret as its password." if
      entry.username.blank? || entry.password.blank?
    { "client_id" => entry.username, "client_secret" => entry.password, "token_endpoint_auth_method" => "client_secret_post" }
  rescue DurableAssistants::Passbolt::Error => problem
    raise McpServer::Unreachable, "Could not read #{name} from the password manager: #{problem.message}"
  end

  # For the gem's OAuth connection (McpServer::Authorization#customize).
  def guard(faraday) = faraday.use(TokenAddress, @server, host)

  private
    def name = @server.vault_entry
    def host = @server.gallery&.last&.dig(:vault_host)
end
