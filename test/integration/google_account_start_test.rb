require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class GoogleAccountStartTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  EXPECTED = "expected-mailbox@example.com"
  CODE = "synthetic-google-code"
  ACCESS = "synthetic-new-access"
  REFRESH = "synthetic-new-refresh"
  START = "/google_account_start"
  CALLBACK = "/connectors/callback"
  SCOPE = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.compose"
  PROFILE = "https://gmail.googleapis.com/gmail/v1/users/me/profile"
  TOKEN = "https://oauth2.googleapis.com/token"
  USER_INFO = "https://openidconnect.googleapis.com/v1/userinfo"
  EMAIL_SCOPE = "https://www.googleapis.com/auth/userinfo.email"
  OLD = { "access_token" => "synthetic-old-access", "refresh_token" => "synthetic-old-refresh", "signed_in_at" => 1 }.freeze
  FETCH = { "Sec-Fetch-Site" => "same-origin", "Origin" => "null" }.freeze

  setup do
    @owner = create_user(name: "GoogleSetupOwner", email: "operator@example.com")
    @connector = make_connector("first_gmail")
    @visitor = outside_browser
    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
  end

  test "signed-out start exchanges the code and checks Gmail before saving only the matched grant, still disabled" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    previous = [ Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger ]
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
    token = issue
    @visitor.get START
    assert_equal 200, @visitor.response.status
    assert_equal "no-referrer", @visitor.response.headers["Referrer-Policy"]
    assert_equal "no-store", @visitor.response.headers["Cache-Control"]
    assert_not_includes @visitor.response.body, token
    assert_nil Nokogiri::HTML(@visitor.response.body).at_css("#google-account-start-submit")["name"]
    @visitor.post START, params: { start_token: token, preview: "1" }, headers: FETCH.merge("Accept" => "text/plain")
    assert_equal 204, @visitor.response.status
    assert_empty @visitor.response.body
    authorization = start(token)
    assert_equal "https://accounts.google.com/o/oauth2/v2/auth", authorization.to_s.split("?").first
    query = URI.decode_www_form(authorization.query).to_h
    assert_equal SCOPE, query.fetch("scope")
    assert_equal "S256", query.fetch("code_challenge_method")
    assert_equal "http://localhost#{CALLBACK}", query.fetch("redirect_uri")
    exchange = exchange_stub(query)
    profile = stub_request(:get, PROFILE).with(headers: { "Authorization" => "Bearer #{ACCESS}" }).to_return do
      assert_equal OLD, @connector.reload.oauth_tokens, "the new grant is not stored during identity inspection"
      { body: { emailAddress: EXPECTED }.to_json }
    end
    callback(query.fetch("state"))
    assert_equal 200, @visitor.response.status
    assert_includes @visitor.response.body, "The requested account matched. The connector is still turned off. You can close this page."
    assert_equal "no-referrer", @visitor.response.headers["Referrer-Policy"]
    assert_equal "no-store", @visitor.response.headers["Cache-Control"]
    assert_requested exchange, times: 1
    assert_requested profile, times: 1
    assert_equal ACCESS, @connector.reload.oauth_tokens["access_token"]
    assert_equal REFRESH, @connector.oauth_tokens["refresh_token"]
    assert_equal "ordinary-state", @connector.oauth_state
    assert_equal({ "ordinary" => true }, @connector.oauth_pending)
    assert_not @connector.enabled?
    @visitor.get "/connectors"
    assert @visitor.response.redirect?, "the callback did not sign the recipient in to the app"
    callback(query.fetch("state"))
    assert_equal 410, @visitor.response.status
    @visitor.post START, params: { start_token: token }, headers: FETCH
    assert_equal 410, @visitor.response.status
    assert_requested exchange, times: 1
    assert_includes output.string, "[FILTERED]"
    [ token, query.fetch("state"), CODE, EXPECTED, ACCESS, REFRESH, "synthetic-client-secret" ].each do |secret|
      assert_not_includes output.string, secret
      assert_not_includes @visitor.response.body, secret
    end
  ensure
    Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger = previous if previous
  end

  test "Calendar and Drive starts ask for identity and save only a verified matching account" do
    %i[ calendar drive ].each_with_index do |kind, index|
      @connector.update!(**McpServer.gallery_attributes(kind), oauth_tokens: OLD)
      scope = @connector.oauth_scope
      query = URI.decode_www_form(start(issue).query).to_h
      assert_equal "#{scope} openid email", query.fetch("scope")
      exchange_stub(query, scope: "#{scope} openid #{EMAIL_SCOPE}")
      info = stub_request(:get, USER_INFO).with(headers: { "Authorization" => "Bearer #{ACCESS}" })
      rejected = info.to_return(body: { email: EXPECTED, email_verified: false, sub: "google-subject" }.to_json)
      callback(query.fetch("state"))
      assert_equal 422, @visitor.response.status
      assert_requested rejected, times: 2 * index + 1
      assert_equal OLD, @connector.reload.oauth_tokens

      query = URI.decode_www_form(start(issue).query).to_h
      exchange_stub(query, scope: "#{scope} openid email #{EMAIL_SCOPE}")
      verified = info.to_return(body: { email: EXPECTED, email_verified: true, sub: "google-subject" }.to_json)
      callback(query.fetch("state"))
      assert_equal 200, @visitor.response.status
      assert_requested verified, times: 2 * index + 2
      assert_equal ACCESS, @connector.reload.oauth_tokens["access_token"]
      assert_equal scope, @connector.oauth_scope
      assert_not @connector.enabled?
    end
    assert_not_requested :get, PROFILE
  end

  test "a mismatched provider email and a provider error preserve all ordinary OAuth state and the old grant" do
    original = @connector.reload.attributes
    query = URI.decode_www_form(start(issue).query).to_h
    exchange_stub(query)
    profile_stub("different-mailbox@example.com")
    callback(query.fetch("state"))
    assert_equal 422, @visitor.response.status
    assert_equal original, @connector.reload.attributes
    assert_not_includes @visitor.response.body, "different-mailbox@example.com"

    query = URI.decode_www_form(start(issue).query).to_h
    @visitor.get CALLBACK, params: { state: query.fetch("state"), error: "access_denied", error_description: "synthetic provider message" }
    assert_equal 422, @visitor.response.status
    assert_not_includes @visitor.response.body, "synthetic provider message"
    assert_equal original, @connector.reload.attributes
  end

  test "a link or callback past expiry, or a superseded attempt, cannot change the connector" do
    original = @connector.reload.attributes
    first = issue
    second = issue
    @visitor.post START, params: { start_token: first }, headers: FETCH
    assert_equal 410, @visitor.response.status
    state = URI.decode_www_form(start(second).query).to_h.fetch("state")
    travel 15.minutes + 1.second
    callback(state)
    assert_equal 410, @visitor.response.status
    expired = issue
    travel 15.minutes + 1.second
    @visitor.post START, params: { start_token: expired }, headers: FETCH
    assert_equal 410, @visitor.response.status
    assert_equal original, @connector.reload.attributes
    assert_not_requested :post, TOKEN
  end

  test "cross-site POST, a different browser, wrong host, and swapped codes cannot complete another start" do
    other_connector = make_connector("second_gmail")
    first = issue
    @visitor.post START, params: { start_token: first }, headers: { "Sec-Fetch-Site" => "cross-site", "Origin" => "https://other.example" }
    assert_includes [ 403, 422 ], @visitor.response.status
    one = URI.decode_www_form(start(first).query).to_h
    two = URI.decode_www_form(start(issue(other_connector)).query).to_h

    assert_equal 410, outside_browser.get(CALLBACK, params: { state: one.fetch("state"), code: CODE })
    @visitor.head "#{CALLBACK}?#{URI.encode_www_form(state: one.fetch("state"), code: CODE)}"
    assert_equal 405, @visitor.response.status
    @visitor.get CALLBACK, params: { state: one.fetch("state"), code: CODE }, headers: { "Host" => "other.example" }
    assert_equal 404, @visitor.response.status
    assert_not_requested :post, TOKEN

    exchange_stub(one, code: "code-from-first-start")
    rejected = stub_request(:post, TOKEN).with { |request|
      body = URI.decode_www_form(request.body).to_h
      body["code"] == "code-from-first-start" && challenge(body["code_verifier"]) == two.fetch("code_challenge")
    }.to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    callback(two.fetch("state"), code: "code-from-first-start", connector_id: @connector.id)
    assert_requested rejected, times: 1
    assert_equal 422, @visitor.response.status
    assert_equal OLD, other_connector.reload.oauth_tokens
    assert_equal OLD, @connector.reload.oauth_tokens

    profile_stub(EXPECTED)
    callback(one.fetch("state"), code: "code-from-first-start", connector_id: other_connector.id)
    assert_equal 200, @visitor.response.status
    assert_equal OLD, other_connector.reload.oauth_tokens
    assert_equal ACCESS, @connector.reload.oauth_tokens["access_token"]
  end

  test "a connector or issuer change while Google answers prevents any write" do
    one = URI.decode_www_form(start(issue).query).to_h
    exchange_stub(one)
    stub_request(:get, PROFILE).to_return do
      @connector.update!(enabled: true)
      { body: { emailAddress: EXPECTED }.to_json }
    end
    callback(one.fetch("state"))
    assert_equal 410, @visitor.response.status
    assert_equal OLD, @connector.reload.oauth_tokens
    assert @connector.enabled?
    @connector.update!(enabled: false)

    two = URI.decode_www_form(start(issue).query).to_h
    exchange_stub(two)
    stub_request(:get, PROFILE).to_return do
      @owner.update!(oidc_sub: "changed-subject")
      { body: { emailAddress: EXPECTED }.to_json }
    end
    callback(two.fetch("state"))
    assert_equal 410, @visitor.response.status
    assert_equal OLD, @connector.reload.oauth_tokens
    assert_equal "ordinary-state", @connector.oauth_state
  end

  test "an alias cannot forward the outside start or callback including its code and state" do
    query = URI.decode_www_form(start(issue).query).to_h
    with_setting(:app, :redirects, "old.example.com") do
      headers = { "Host" => "old.example.com" }
      @visitor.get START, headers: headers
      assert_equal 404, @visitor.response.status
      @visitor.get CALLBACK, params: { state: query.fetch("state"), code: CODE }, headers: headers
      assert_equal 404, @visitor.response.status
      assert_nil @visitor.response.location
      @visitor.get CALLBACK, params: { state: query.fetch("state"), code: CODE },
        headers: headers.merge("X-Forwarded-Host" => "localhost")
      assert_equal 404, @visitor.response.status
      assert_nil @visitor.response.location
      @visitor.get "/connectors", headers: headers
      assert_equal "http://localhost/connectors", @visitor.response.location
    end
    assert_not_requested :post, TOKEN
  end

  test "a different issuer, expanded scopes, malformed profile or revoked admission cannot replace a grant" do
    state = URI.decode_www_form(start(issue).query).to_h.fetch("state")
    @visitor.get CALLBACK, params: { state: state, code: CODE, iss: "https://other.example" }
    assert_equal 422, @visitor.response.status
    assert_not_requested :post, TOKEN

    query = URI.decode_www_form(start(issue).query).to_h
    extra_scope = exchange_stub(query, scope: "#{SCOPE} openid email")
    callback(query.fetch("state"))
    assert_equal 422, @visitor.response.status
    assert_requested extra_scope
    assert_not_requested :get, PROFILE

    query = URI.decode_www_form(start(issue).query).to_h
    exchange_stub(query)
    stub_request(:get, PROFILE).to_return(status: 502, body: "malformed provider message")
    callback(query.fetch("state"))
    assert_equal 422, @visitor.response.status
    assert_not_includes @visitor.response.body, "malformed provider message"

    query = URI.decode_www_form(start(issue).query).to_h
    with_setting(:access, :emails, []) { callback(query.fetch("state")) }
    assert_equal 410, @visitor.response.status
    assert_equal OLD, @connector.reload.oauth_tokens
    assert_equal "ordinary-state", @connector.oauth_state
  end

  test "only the workspace owner or connector creator can issue for a disabled eligible conversation connector" do
    workspace = Workspace.create!(name: "Synthetic shared workspace")
    owner = create_user(name: "SharedOwner", email: "member@example.com")
    outsider = create_user(name: "NotCreator", email: "other@example.com")
    workspace.memberships.create!(user: owner, role: :owner)
    workspace.memberships.create!(user: @owner, role: :member)
    workspace.memberships.create!(user: outsider, role: :member)
    conversation = @owner.start_agent("Synthetic", workspace: workspace).conversation
    connector = workspace.mcp_servers.create!(@connector.attributes.slice("url", "oauth_scope", "oauth_client").merge(
      user: @owner, name: "shared_gmail", enabled: false, conversation: conversation))
    issue(connector)
    with_setting(:access, :emails, [ owner.email, outsider.email ]) do
      sign_in_via_ajent(subject: owner.oidc_sub, email: owner.email, name: owner.name)
      issue(connector)
      sign_in_via_ajent(subject: outsider.oidc_sub, email: outsider.email, name: outsider.name)
      post connector_google_account_start_path(connector), params: { expected_email: EXPECTED }
      assert_response :not_found
    end

    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
    connector.update!(enabled: true)
    post connector_google_account_start_path(connector), params: { expected_email: EXPECTED }
    assert_response :not_found
    connector.update!(enabled: false, url: "https://calendarmcp.googleapis.com/mcp/v1",
      oauth_scope: "https://www.googleapis.com/auth/calendar.events")
    post connector_google_account_start_path(connector), params: { expected_email: EXPECTED }
    assert_response :not_found
  end

  test "private start pages and callbacks never go into visit analytics" do
    track_bots, Ahoy.track_bots = Ahoy.track_bots, true
    assert_no_difference -> { Ahoy::Visit.count } do
      @visitor.get START
      assert_equal 200, @visitor.response.status
      @visitor.get CALLBACK, params: { state: "gstart.#{"s" * 43}", code: CODE }
      assert_equal 410, @visitor.response.status
      issue
    end
  ensure
    Ahoy.track_bots = track_bots
  end

  test "honors the configured web client authentication method" do
    @connector.update!(oauth_client: @connector.oauth_client.merge("token_endpoint_auth_method" => "client_secret_basic"))
    query = URI.decode_www_form(start(issue).query).to_h
    exchange = stub_request(:post, TOKEN).with(basic_auth: [ "synthetic-client-id", "synthetic-client-secret" ]) do |request|
      body = URI.decode_www_form(request.body).to_h
      body["code"] == CODE && challenge(body["code_verifier"]) == query.fetch("code_challenge") &&
        body.keys.exclude?("client_id") && body.keys.exclude?("client_secret")
    end.to_return(body: { access_token: ACCESS, refresh_token: REFRESH, expires_in: 3600, token_type: "Bearer", scope: SCOPE }.to_json)
    profile_stub(EXPECTED)

    callback(query.fetch("state"))

    assert_equal 200, @visitor.response.status
    assert_requested exchange
    refute @connector.reload.enabled?
  end

  test "both callback branches refuse a signed-out request with the wrong state" do
    state = URI.decode_www_form(start(issue).query).to_h.fetch("state")
    wrong_state = state.sub(/.$/) { |last| last == "A" ? "B" : "A" }
    original = @connector.reload.attributes

    @visitor.get CALLBACK, params: { state: "unknown-ordinary-state", code: CODE }
    assert_equal 400, @visitor.response.status
    assert_equal "no-store", @visitor.response.headers["Cache-Control"]

    callback(wrong_state)
    assert_equal 410, @visitor.response.status
    assert_equal "no-store", @visitor.response.headers["Cache-Control"]
    assert_nil @connector.google_account_starts.sole.finished_at
    assert_equal original, @connector.reload.attributes
    assert_not_requested :post, TOKEN
    assert_not_requested :get, PROFILE

    @visitor.get "/connectors"
    assert_equal "/sign_in", URI(@visitor.response.location).path
  end

  private
    def make_connector(name)
      @owner.personal_workspace.mcp_servers.create!(user: @owner, name: name, enabled: false,
        url: "https://gmailmcp.googleapis.com/mcp/v1", oauth_scope: SCOPE, conversation: @owner.agents.sole.conversation,
        oauth_client: { "client_id" => "synthetic-client-id", "client_secret" => "synthetic-client-secret", "token_endpoint_auth_method" => "client_secret_post" },
        oauth_tokens: OLD, oauth_state: ("ordinary-state" if name == "first_gmail"), oauth_pending: { "ordinary" => true })
    end

    def outside_browser = open_session.tap { it.host! "localhost" }

    def issue(connector = @connector)
      post "/connectors/#{connector.id}/google_account_start", params: { expected_email: EXPECTED }
      assert_response :created
      assert_equal "no-store", response.headers["Cache-Control"]
      link = URI(css_select("#google-account-start-link").sole["value"])
      assert_equal START, link.path
      assert_nil link.query
      link.fragment
    end

    def start(token)
      @visitor.post START, params: { start_token: token }, headers: FETCH
      assert_equal 303, @visitor.response.status
      URI(@visitor.response.location)
    end

    def callback(state, code: CODE, **extra)
      @visitor.get CALLBACK, params: { state: state, code: code, iss: "https://accounts.google.com", **extra }
    end

    def exchange_stub(query, code: CODE, scope: SCOPE)
      stub_request(:post, TOKEN).with { |request|
        body = URI.decode_www_form(request.body).to_h
        body["grant_type"] == "authorization_code" && body["code"] == code &&
          body["client_id"] == query.fetch("client_id") && body["client_secret"] == "synthetic-client-secret" &&
          body["redirect_uri"] == query.fetch("redirect_uri") && challenge(body["code_verifier"]) == query.fetch("code_challenge")
      }.to_return(body: { access_token: ACCESS, refresh_token: REFRESH, expires_in: 3600, token_type: "Bearer", scope: scope }.to_json)
    end

    def challenge(verifier) = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier.to_s), padding: false)

    def profile_stub(email)
      stub_request(:get, PROFILE).with(headers: { "Authorization" => "Bearer #{ACCESS}" }).to_return(body: { emailAddress: email }.to_json)
    end
end
