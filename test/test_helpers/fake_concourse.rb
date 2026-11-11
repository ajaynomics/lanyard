require "rack"

# A stand-in for Concourse's join (its /connect pages, /connect/token and
# /connect/revoke), its /api/identity, and Ajent's client_credentials grant,
# as one Rack app, built to the contract agreed with Concourse (docs/design.md,
# "Joining Concourse"). Model and controller tests reach it through WebMock
# (`stub_request(...).to_rack`); the browser tests boot it on localhost.
#
# It checks what the real one is to check: the exact redirect address, PKCE
# S256 against the verifier, `state` passed back, one use per code within ten
# minutes. The person on its page approves at once into `organization` with
# the proposed handle, or cancels (`cancel: true`). A new agent waits for an
# owner's approval unless `admit_on_join: true`; `admit!` and `decline!` are
# that owner. An agent's address on the wire is its A2A URL,
# <origin>/a2a/<organization>/<prefix>/<handle>; here the prefix is the
# organization, and `address` is "prefix/handle". `wire_address`, a lambda of
# the agent and the origin, sends another.
class FakeConcourse
  Agent = Struct.new(:address, :organization, :handle, :client_id, :client_secret, :status, :id, keyword_init: true)

  attr_reader :agents, :authorizations, :revocations
  attr_accessor :organization, :cancel, :admit_on_join, :revoke_status, :revoke_reason, :token_endpoint, :wire_address

  def initialize(redirect_uri:, organization: "acme", token_endpoint: nil, admit_on_join: false)
    @redirect_uri, @organization, @token_endpoint, @admit_on_join = redirect_uri, organization, token_endpoint, admit_on_join
    @codes, @tokens, @agents, @authorizations, @revocations = {}, {}, [], [], []
    @counter = 0
  end

  def admit!(address = agents.last.address) = find(address).status = "admitted"
  def decline!(address = agents.last.address) = find(address).status = "declined"

  def call(env)
    request = Rack::Request.new(env)
    base = request.base_url
    case [ request.request_method, request.path ]
    in [ "GET", "/connect" ] then connect(request.GET)
    in [ "POST", "/connect/token" ] then redeem(request.POST, base)
    in [ "POST", "/connect/revoke" ] then revoke(bearer(request))
    in [ "POST", "/oauth/token" ] then grant(request)
    in [ "GET", "/api/identity" ] then identity(bearer(request))
    else [ 404, {}, [] ]
    end
  end

  private
    def find(address) = agents.find { it.address == address }

    # The page the person sees: here, their answer at once.
    def connect(params)
      @authorizations << params
      return [ 400, {}, [ "unknown redirect address" ] ] unless params["redirect_uri"] == @redirect_uri
      return [ 400, {}, [ "PKCE S256 required" ] ] unless params["code_challenge_method"] == "S256" && params["code_challenge"].to_s.size == 43
      return [ 400, {}, [ "bad request" ] ] unless params["response_type"] == "code" && params["state"].present? &&
        params["handle"].to_s.match?(/\A[a-zA-Z0-9_-]{1,100}\z/) && params["name"].present? && params["app_name"].present?
      answer = if cancel
        { error: "access_denied", state: params["state"] }
      else
        code = "code-#{@counter += 1}"
        @codes[code] = params.slice("redirect_uri", "code_challenge", "handle").merge("issued_at" => Time.now.to_i)
        { code: code, state: params["state"] }
      end
      [ 302, { "location" => "#{params["redirect_uri"]}?#{URI.encode_www_form(answer)}" }, [] ]
    end

    def redeem(form, base)
      return oauth_error("unsupported_grant_type") unless form["grant_type"] == "authorization_code"
      code = @codes.delete(form["code"])
      return oauth_error("invalid_grant") unless code && Time.now.to_i - code["issued_at"] <= 600 && code["redirect_uri"] == form["redirect_uri"] &&
        Base64.urlsafe_encode64(Digest::SHA256.digest(form["code_verifier"].to_s), padding: false) == code["code_challenge"]
      number = @counter += 1
      agent = Agent.new(address: "#{@organization}/#{code["handle"]}", organization: @organization, handle: code["handle"], id: number,
        client_id: "joined-#{number}", client_secret: "joined-secret-#{number}", status: admit_on_join ? "admitted" : "awaiting_approval")
      @agents << agent
      url = wire_address ? wire_address.(agent, base) : "#{base}/a2a/#{agent.organization}/#{agent.organization}/#{agent.handle}"
      json agent: { address: url, **agent.to_h.slice(:organization, :handle, :status) }, client_id: agent.client_id, client_secret: agent.client_secret,
        token_endpoint: token_endpoint || "#{base}/oauth/token", scope: "concourse", resources: { api_and_a2a: base, mcp: "#{base}/mcp" }
    end

    # Ajent's client_credentials grant, for the agents this made.
    def grant(request)
      id, secret = Base64.decode64(request.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Basic ")).split(":", 2).map { URI.decode_www_form_component(it.to_s) }
      agent = agents.find { it.client_id == id && it.client_secret == secret && it.status != "retired" }
      return json({ error: "invalid_client" }, status: 401) unless agent && request.POST.values_at("grant_type", "scope") == %w[ client_credentials concourse ]
      token = "token-#{@counter += 1}"
      @tokens[token] = agent
      json access_token: token, token_type: "Bearer", expires_in: 3600, scope: "concourse"
    end

    def identity(agent)
      case agent&.status
      when "admitted"
        json owner_id: 3, owner: "maya", organization: agent.organization, agent_id: agent.id, oauth_client_id: agent.client_id,
          handle: agent.handle, release_line: 3, prefix: agent.organization
      when "awaiting_approval", "declined" then json({ error: "not_a_member", reason: agent.status }, status: 403)
      else json({ error: "invalid_token" }, status: 401)
      end
    end

    def revoke(agent)
      @revocations << agent&.address
      return json({ error: "forbidden", reason: revoke_reason }.compact, status: revoke_status) if revoke_status
      return json({ error: "invalid_token" }, status: 401) unless agent && agent.status != "retired"
      agent.status = "retired"
      [ 204, {}, [] ]
    end

    def bearer(request) = @tokens[request.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Bearer ")].then { it unless it&.status == "retired" }

    def oauth_error(error) = json({ error: error }, status: 400)

    def json(body = nil, status: 200, **fields) = [ status, { "content-type" => "application/json" }, [ (body || fields).to_json ] ]
end
