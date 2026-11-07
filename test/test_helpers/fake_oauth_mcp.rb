require "rack"

# A stand-in for an MCP server that asks for sign-in, with its own
# authorization server, as one Rack app: what Linear or Notion run, small
# enough to read. Model and controller tests reach it through WebMock
# (`stub_request(...).to_rack`); the browser tests boot it on localhost.
#
# It checks what a real one checks: a registered client and redirect address,
# PKCE S256 against the verifier, `state` passed back, the `resource`, one use
# per code and refresh token. `expire!` makes the current access tokens fail,
# as a server does when they lapse. `open_listing: true` lists its tools to
# anyone and asks for sign-in only when one is called, as Google's do.
class FakeOauthMcp
  attr_reader :registrations, :token_requests, :tools_listed

  def initialize(tools: [ { name: "echo", description: "Says it back.", annotations: { readOnlyHint: true },
                            inputSchema: { type: "object", properties: { text: { type: "string" } } } } ], expires_in: 3600, open_listing: false)
    @tools, @expires_in, @open_listing = tools, expires_in, open_listing
    @clients, @codes, @access, @refresh = {}, {}, Set.new, Set.new
    @registrations, @token_requests, @tools_listed = [], [], 0
    @counter = 0
  end

  def expire! = @access.clear

  def call(env)
    request = Rack::Request.new(env)
    base = request.base_url
    case [ request.request_method, request.path ]
    in [ "GET", "/.well-known/oauth-protected-resource/mcp" ]
      json resource: "#{base}/mcp", authorization_servers: [ base ]
    in [ "GET", "/.well-known/oauth-authorization-server" ]
      json issuer: base, authorization_endpoint: "#{base}/authorize", token_endpoint: "#{base}/token",
        registration_endpoint: "#{base}/register", code_challenge_methods_supported: %w[ S256 ],
        grant_types_supported: %w[ authorization_code refresh_token ], response_types_supported: %w[ code ]
    in [ "POST", "/register" ] then register(JSON.parse(request.body.read))
    in [ "GET", "/authorize" ] then authorize(request.params, base)
    in [ "POST", "/token" ] then token(request.POST)
    in [ "POST", "/mcp" ] then mcp(request, base)
    in [ "DELETE", "/mcp" ] then [ 200, {}, [] ]
    else [ 404, {}, [] ]
    end
  end

  private
    def register(metadata)
      @registrations << metadata
      client_id = "client-#{@counter += 1}"
      @clients[client_id] = metadata["redirect_uris"]
      json({ client_id: client_id, client_id_issued_at: Time.now.to_i }.merge(metadata.slice("redirect_uris", "grant_types", "token_endpoint_auth_method")), status: 201)
    end

    # Approves at once, as a person clicking "Allow" would.
    def authorize(params, base)
      return [ 400, {}, [ "unknown client" ] ] unless Array(@clients[params["client_id"]]).include?(params["redirect_uri"])
      return [ 400, {}, [ "PKCE S256 required" ] ] unless params["code_challenge_method"] == "S256" && params["code_challenge"].present?
      return [ 400, {}, [ "wrong resource" ] ] unless params["resource"] == "#{base}/mcp"
      code = "code-#{@counter += 1}"
      @codes[code] = params.slice("client_id", "redirect_uri", "code_challenge", "resource")
      [ 302, { "location" => "#{params['redirect_uri']}?#{URI.encode_www_form(code: code, state: params['state'], iss: base)}" }, [] ]
    end

    def token(form)
      @token_requests << form
      case form["grant_type"]
      when "authorization_code"
        grant = @codes.delete(form["code"])
        return oauth_error("invalid_grant") unless grant && grant["client_id"] == form["client_id"] && grant["redirect_uri"] == form["redirect_uri"]
        return oauth_error("invalid_grant", "PKCE verifier does not match") unless
          Base64.urlsafe_encode64(Digest::SHA256.digest(form["code_verifier"].to_s), padding: false) == grant["code_challenge"]
        return oauth_error("invalid_target") unless form["resource"] == grant["resource"]
      when "refresh_token"
        return oauth_error("invalid_grant") unless @refresh.delete?(form["refresh_token"])
      else
        return oauth_error("unsupported_grant_type")
      end
      issue
    end

    def issue
      access, refresh = "at-#{@counter += 1}", "rt-#{@counter += 1}"
      @access << access
      @refresh << refresh
      json access_token: access, token_type: "Bearer", expires_in: @expires_in, refresh_token: refresh
    end

    def mcp(request, base)
      token = request.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Bearer ")
      message = JSON.parse(request.body.read)
      listing = @open_listing && message["method"] != "tools/call"
      unless listing || @access.include?(token)
        return [ 401, { "www-authenticate" => %(Bearer resource_metadata="#{base}/.well-known/oauth-protected-resource/mcp") }, [] ]
      end
      case message["method"]
      when "initialize"
        reply message, protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake", version: "1" }
      when "notifications/initialized" then [ 202, {}, [] ]
      when "tools/list"
        @tools_listed += 1
        reply message, tools: @tools
      when "tools/call"
        reply message, content: [ { type: "text", text: "echo: #{message.dig('params', 'arguments', 'text')}" } ]
      else [ 400, {}, [] ]
      end
    end

    def reply(message, result) = json(jsonrpc: "2.0", id: message["id"], result: result)

    def oauth_error(error, description = nil) = json({ error: error, error_description: description }.compact, status: 400)

    def json(body = nil, status: 200, **fields) = [ status, { "content-type" => "application/json" }, [ (body || fields).to_json ] ]
end
