require "rack"

# A stand-in for Ajent as one Rack app: its discovery document, key set, token
# endpoint and user info, which is all the real OmniAuth strategy calls. Tests
# reach it through WebMock (`stub_request(...).to_rack`), so the whole sign-in
# runs the real strategy and no network.
#
# It checks what Ajent checks: the registered client and secret, the redirect
# address, PKCE S256 against the verifier, `state` and `nonce` passed back, one
# use per code, and an RS256 ID token for this client. A test that skips any of
# it by mistake fails here, not in production.
class FakeAjent
  URLS = %r{\Ahttps?://www\.example\.com/(\.well-known/openid-configuration|oidc/)}

  attr_accessor :claims

  def initialize(sub: "ajent-maya", email: "operator@example.com", name: "Maya", email_verified: true)
    oidc = Rails.application.config.x.oidc
    @issuer, @client_id, @client_secret, @redirect_uri = oidc.issuer, oidc.client_id, oidc.client_secret, oidc.callback_uri
    @claims = { sub: sub, email: email, name: name, email_verified: email_verified }
    @key = OpenSSL::PKey::RSA.generate(2048)
    @codes, @access = {}, {}
    @counter = 0
  end

  # The browser reaches the authorization endpoint, and the person says yes:
  # the address Ajent sends them back to.
  def approve(authorization_url)
    params = authorization_request(authorization_url)
    code = "code-#{@counter += 1}"
    @codes[code] = params.slice("code_challenge", "nonce")
    "#{@redirect_uri}?#{URI.encode_www_form(code: code, state: params['state'])}"
  end

  # ...or no.
  def deny(authorization_url)
    "#{@redirect_uri}?#{URI.encode_www_form(error: 'access_denied', state: authorization_request(authorization_url)['state'])}"
  end

  def call(env)
    request = Rack::Request.new(env)
    base = request.base_url
    case [ request.request_method, request.path ]
    in [ "GET", "/.well-known/openid-configuration" ]
      json issuer: @issuer, authorization_endpoint: "#{base}/oidc/authorize", token_endpoint: "#{base}/oidc/token",
        userinfo_endpoint: "#{base}/oidc/userinfo", jwks_uri: "#{base}/oidc/jwks", response_types_supported: %w[ code ],
        subject_types_supported: %w[ public ], id_token_signing_alg_values_supported: %w[ RS256 ],
        code_challenge_methods_supported: %w[ S256 ]
    in [ "GET", "/oidc/jwks" ] then json keys: [ JSON::JWK.new(@key.public_key, kid: "ajent-key-1") ]
    in [ "POST", "/oidc/token" ] then token(request)
    in [ "GET", "/oidc/userinfo" ] then userinfo(request)
    else [ 404, {}, [] ]
    end
  end

  private
    def authorization_request(url)
      params = Rack::Utils.parse_query(URI(url).query)
      raise "unknown client" unless params["client_id"] == @client_id
      raise "unregistered redirect address" unless params["redirect_uri"] == @redirect_uri
      raise "not an OpenID request" unless params["response_type"] == "code" && params["scope"].to_s.split.include?("openid")
      raise "PKCE S256 required" unless params["code_challenge_method"] == "S256" && params["code_challenge"].present?
      raise "state and nonce required" unless params["state"].present? && params["nonce"].present?
      params
    end

    def token(request)
      params = request.POST
      client = Rack::Auth::Basic::Request.new(request.env).credentials
      return json({ error: "invalid_client" }, 401) unless client == [ @client_id, @client_secret ]
      grant = @codes.delete(params["code"])
      return json({ error: "invalid_grant" }, 400) unless grant && params["redirect_uri"] == @redirect_uri
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(params["code_verifier"].to_s), padding: false)
      return json({ error: "invalid_grant", error_description: "PKCE failed" }, 400) unless challenge == grant["code_challenge"]

      now = Time.current.to_i
      id_token = JSON::JWT.new(iss: @issuer, sub: @claims[:sub], aud: @client_id, iat: now, exp: now + 300, nonce: grant["nonce"])
      id_token.kid = "ajent-key-1"
      access_token = "token-#{@counter += 1}"
      @access[access_token] = true
      json access_token: access_token, token_type: "Bearer", expires_in: 3600, id_token: id_token.sign(@key, :RS256).to_s
    end

    def userinfo(request)
      return [ 401, {}, [] ] unless @access[request.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Bearer ")]
      json @claims
    end

    def json(body, status = 200) = [ status, { "content-type" => "application/json" }, [ body.to_json ] ]
end

module FakeAjentTestHelper
  # The real strategy, not OmniAuth's test mode: begin sign-in, let the fake
  # approve, and return to the callback. Returns the response of that return.
  def sign_in_through(ajent)
    stub_request(:any, FakeAjent::URLS).to_rack(ajent)
    post ajent_auth_path
    assert_response :redirect
    get ajent.approve(response.location)
  end
end
