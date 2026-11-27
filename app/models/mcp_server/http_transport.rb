# The `mcp` gem's HTTP transport for a connector whose refresh token is good
# once (McpServer#rotating_refresh?): the refresh it tries when the server
# answers 401 goes through McpServer::Renewal. The gem's own would send the
# refresh token unclaimed while another call may be spending it, and one sent
# twice costs the sign-in. Every other connector uses the gem's transport.
class McpServer::HttpTransport < MCP::Client::HTTP
  def initialize(server, **, &)
    @server = server
    super(**, &)
  end

  private
    # The gem has no public hook for this refresh, so this overrides its
    # private MCP::Client::HTTP#attempt_refresh (pinned in the
    # Gemfile; test/models/mcp_server/http_transport_test.rb fails by name if
    # it moves). True sends the request once more, with the tokens the
    # connector now holds. With no refresh token the gem goes on as before,
    # to a new sign-in.
    def attempt_refresh(flow:, resource_metadata_url:)
      refresh_token_available? && McpServer::Renewal.new(@server).renew(rejected: oauth.access_token)
    end
end
