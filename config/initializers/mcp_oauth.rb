# The `mcp` gem checks the authorization server's `issuer` byte for byte
# against the address the server's own metadata named (RFC 8414 3.3), and that
# is right. Google's MCP servers name its sign-in service "https://accounts.google.com/"
# but its metadata says "https://accounts.google.com", so every Google connector
# fails the check. This allows that one trailing slash for that one issuer and
# keeps the check strict for every other server.
module McpOauthGoogleIssuer
  GOOGLE = "https://accounts.google.com"

  private
    def ensure_issuer_matches!(expected:, returned:)
      return if expected.to_s.chomp("/") == GOOGLE && returned.to_s == GOOGLE
      super
    end
end

MCP::Client::OAuth::Flow.prepend(McpOauthGoogleIssuer)
