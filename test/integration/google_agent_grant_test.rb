require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class GoogleAgentGrantTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  MAILBOX = "named-mailbox@example.com"
  START = "/google_account_start"
  CALLBACK = "/connectors/callback"
  TOKEN = "https://oauth2.googleapis.com/token"
  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
  PROFILE = "#{GMAIL}/profile"
  CONTENT = %r{https://gmail\.googleapis\.com/gmail/v1/users/me/(?!profile\b)}
  SCOPE = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.compose"
  FETCH = { "Sec-Fetch-Site" => "same-origin", "Origin" => "null" }.freeze

  setup do
    @owner = create_user(name: "GrantOwner", email: "operator@example.com")
    @member = create_user(name: "GrantMember", email: "member@example.com")
    @workspace = @owner.personal_workspace
    @workspace.memberships.create!(user: @member, role: :member)
    @agent = @owner.agents.sole
    @other = @owner.start_agent("Other grant agent")
    @connector = @agent.conversation.mcp_servers.create!(**McpServer.gallery_attributes(:gmail),
      user: @member, name: "delegated_gmail", enabled: false)
    @visitor = open_session.tap { it.host! "localhost" }
    @apps = Rails.application.config.x.connectors[:apps]
    Rails.application.config.x.connectors[:apps] = { google: { client_id: "install-client", client_secret: "synthetic-install-secret" } }
    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
    forbid_content
  end

  teardown { Rails.application.config.x.connectors[:apps] = @apps }

  test "an unspent link expires and a successful link works only once" do
    expired = issue
    travel 15.minutes + 1.second
    spend(expired, status: 410)
    assert_not_requested :post, TOKEN

    link = issue
    query = spend(link)
    spend(link, status: 410)
    complete(query)
    assert_equal 200, @visitor.response.status
    callback(query)
    assert_equal 410, @visitor.response.status
    assert_requested :post, TOKEN, times: 1
    assert @connector.reload.enabled?, "only the consented connector turns on"
  end

  test "the recipient sees the grant is on for the intended agent, not a callback parameter" do
    complete(spend(issue), agent_id: @other.id)
    assert_equal 200, @visitor.response.status
    assert_includes @visitor.response.body, "Gmail search is now on for #{@agent.name}."
    refute_includes @visitor.response.body, "The connector is still turned off."
    refute_includes @visitor.response.body, @other.name
    assert @connector.reload.enabled?
  end

  test "a valid preview returns only the agent name without spending the link" do
    @workspace.update!(name: "Synthetic workspace")
    token = issue
    @visitor.get START
    refute_includes Nokogiri::HTML(@visitor.response.body).at_css("main").text, @agent.name

    preview(token, headers: { "Sec-Fetch-Site" => "cross-site", "Origin" => "https://other.example" })
    assert_equal 403, @visitor.response.status
    preview(token)
    assert_equal 200, @visitor.response.status
    assert_equal "text/plain", @visitor.response.media_type
    assert_equal "no-store", @visitor.response.headers["Cache-Control"]
    [ @workspace.name, @owner.name, @owner.email, MAILBOX, @connector.name ].each do |private_value|
      refute_includes @visitor.response.body, private_value
    end
    assert_equal @agent.name, @visitor.response.body
    assert_nil @connector.google_account_starts.sole.started_at
    assert_not_requested :post, TOKEN
    assert_not_requested :get, PROFILE
    spend(token)
  end

  test "unknown, malformed, spent and expired previews have the same empty response and lookup shape" do
    spent = issue
    spend(spent)
    spent_response = preview_snapshot(spent)
    expired = issue
    travel 15.minutes + 1.second

    unknown = preview_snapshot("x" * 40)
    [ spent_response, preview_snapshot(expired), preview_snapshot("malformed") ].each { assert_equal unknown, it }
    assert_equal 1, unknown.last.size
    assert_empty unknown[1]
  end

  test "a used or expired link fails preview instead of offering to continue" do
    spent = issue
    spend(spent)
    preview(spent)
    spent_status = @visitor.response.status
    expired = issue
    travel 15.minutes + 1.second
    preview(expired)
    assert_equal [ 410, 410 ], [ spent_status, @visitor.response.status ]
  end

  test "preview rejects unknown tokens and filters the submitted token in Rails logs" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    previous = [ Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger ]
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
    token = "testsecret".ljust(40, "x")
    preview(token)
    assert_match(/"start_token"\s*=>\s*"\[FILTERED\]"/, output.string)
    refute_includes output.string, token
    assert_equal 410, @visitor.response.status
    assert_empty @visitor.response.body
  ensure
    Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger = previous if previous
  end

  test "local revoke explains what it leaves in Google and in earlier reads before the owner acts" do
    complete(spend(issue))
    get conversation_connectors_path(@agent.conversation)
    assert_select "#mcp_server_#{@connector.id} p", text: "Revoking here stops #{@agent.name}'s searches. It doesn't remove the permission you gave in Google or undo earlier reads; manage that in your Google Account settings." do
      assert_select "a[href=?]", "https://myaccount.google.com/permissions", text: "Google Account settings"
    end
  end

  test "the revoked receipt keeps the limits and Google permissions link after reload" do
    complete(spend(issue))
    delete connector_sign_in_path(@connector)
    assert_response :redirect
    get conversation_connectors_path(@agent.conversation)
    assert_select "#mcp_server_#{@connector.id} p", text: "Revoking here stopped #{@agent.name}'s searches. It didn't remove the permission you gave in Google or undo earlier reads; manage that in your Google Account settings." do
      assert_select "a[href=?]", "https://myaccount.google.com/permissions", text: "Google Account settings"
    end
  end

  test "a mixed Gmail catalogue offers the granted account for search only" do
    complete(spend(issue))
    conversation = @agent.conversation
    ordinary = conversation.mcp_servers.create!(**McpServer.gallery_attributes(:gmail),
      user: @owner, name: "ordinary_gmail", refreshed_at: Time.current,
      oauth_tokens: { "access_token" => "synthetic-ordinary-access", "expires_at" => 1.hour.from_now.to_i })
    ordinary.tool_classes.each do |member|
      name = member.listing.fetch("name")
      tool = conversation.tool("mcp__gmail__#{name}")
      account = tool.schema.fetch("properties").fetch("account")
      if name == "search_threads"
        assert_equal %w[ delegated_gmail ordinary_gmail ], account["enum"]
        assert_includes account["description"], "delegated_gmail"
      else
        assert_equal %w[ ordinary_gmail ], account["enum"], name
        refute_includes account["description"], "delegated_gmail", name
      end
    end
  end

  test "the target is the exact connector and agent, not an input a callback can replace" do
    token = issue
    query = spend(token)
    @connector.update_column(:conversation_id, @other.conversation.id)
    callback(query)
    assert_equal 410, @visitor.response.status
    assert_not_requested :post, TOKEN
    assert_nil @connector.reload.oauth_tokens
    post connector_google_account_start_path(@connector), params: { expected_email: MAILBOX, agent_id: @other.id }
    assert_response :not_found, "moving a connector must not let a new agent take over its grant"

    @connector.update_column(:conversation_id, @agent.conversation.id)
    post connector_google_account_start_path(@connector), params: { expected_email: MAILBOX, agent_id: @other.id }
    assert_response :not_found
    query = spend(issue)
    complete(query, agent_id: @other.id)
    assert_equal 200, @visitor.response.status
    assert_raises(McpServer::SignInNeeded) { search(@other.conversation) }
    assert_raises(McpServer::SignInNeeded) { @connector.reload.call_tool("search_threads", {}) }
    assert_empty @other.conversation.connectors
    assert_equal [ "search_threads" ], @connector.reload.listing.pluck("name")
  end

  test "a different Gmail profile stores no grant and only the named mailbox can turn it on" do
    query = spend(issue)
    complete(query, email: "other@example.com")
    assert_equal 422, @visitor.response.status
    assert_nil @connector.reload.oauth_tokens
    refute @connector.enabled?
    get conversation_connectors_path(@agent.conversation)
    assert_select "[data-gmail-grant]", text: /Granted/, count: 0

    query = spend(issue)
    complete(query)
    assert_equal 200, @visitor.response.status
    assert @connector.reload.enabled?
  end

  test "state and browser must match and a bad scope never reaches the Gmail profile" do
    query = spend(issue)
    wrong = query.merge("state" => "gstart.#{'x' * 43}")
    assert_equal 410, callback(wrong)
    assert_equal 410, callback(query, browser: open_session.tap { it.host! "localhost" })
    assert_not_requested :post, TOKEN
    assert_not_requested :get, PROFILE

    [ SCOPE.split.first, "#{SCOPE} openid" ].each do |scope|
      exchange_stub(query, scope: scope)
      assert_equal 422, callback(query)
      assert_nil @connector.reload.oauth_tokens
      assert_not_requested :get, PROFILE
      query = spend(issue)
    end

    complete(query)
    assert_equal 200, @visitor.response.status
    assert @connector.reload.enabled?
  end

  test "a competing callback cannot publish a second grant" do
    query = spend(issue)
    exchange_stub(query)
    competitor = open_session.tap { it.host! "localhost" }
    cookie = "google_account_start=#{@visitor.cookies['google_account_start']}"
    profile_stub do
      assert_nil @connector.reload.oauth_tokens
      assert_equal 410, callback(query, browser: competitor, headers: { "Cookie" => cookie })
    end
    assert_equal 200, callback(query)
    assert_requested :post, TOKEN, times: 1
    assert_requested :get, PROFILE, times: 1
    assert @connector.reload.enabled?
  end

  test "owner revoke during the profile request cancels publication and keeps the connector off" do
    query = spend(issue)
    exchange_stub(query)
    profile_stub do
      delete connector_sign_in_path(@connector)
      assert_response :redirect
    end
    assert_equal 410, callback(query)
    assert_nil @connector.reload.oauth_tokens
    refute @connector.enabled?
    patch connector_path(@connector), params: { connector: { enabled: true } }
    assert_response :not_found
    refute @connector.reload.enabled?
  end

  test "Gmail content is available only after consent and unavailable after revoke even through an old object" do
    query = spend(issue)
    assert_raises(McpServer::SignInNeeded) { search }
    assert_not_requested :post, TOKEN
    assert_not_requested :get, PROFILE
    assert_not_requested :any, CONTENT
    complete(query)
    assert_equal 200, @visitor.response.status
    get_request = stub_request(:get, %r{#{GMAIL}/threads\?}).with(headers: { "Authorization" => "Bearer synthetic-access" })
      .to_return(body: { threads: [] }.to_json)
    stale = @workspace.mcp_servers.find(@connector.id)
    search
    assert_requested get_request, times: 1
    assert_raises(McpServer::SignInNeeded) { McpServer::Google.new(stale).read_gmail_inbox { it.profile } }
    assert_raises(McpServer::SignInNeeded) { stale.call_tool("list_labels", {}, conversation: @agent.conversation) }
    delete connector_sign_in_path(@connector)
    assert_response :redirect
    forbid_content
    assert_raises(McpServer::SignInNeeded) { stale.call_tool("search_threads", {}, conversation: @agent.conversation) }
    assert_requested get_request, times: 1
    assert_requested :post, TOKEN, times: 1
    assert_requested :get, PROFILE, times: 1
    assert_nil @connector.reload.oauth_tokens
    refute @connector.enabled?
  end

  test "the owner alone can issue, see the receipt and revoke" do
    as_member do
      post connector_google_account_start_path(@connector), params: { expected_email: MAILBOX, agent_id: @agent.id }
      assert_response :not_found
    end
    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
    travel_to Time.zone.local(2026, 11, 22, 11, 45)
    get conversation_connectors_path(@agent.conversation)
    assert_select "form[action=?] input[name=agent_id][value=?]", connector_google_account_start_path(@connector), @agent.id.to_s
    query = spend(issue)
    complete(query)
    assert_equal 200, @visitor.response.status
    get conversation_connectors_path(@agent.conversation)
    assert_response :success
    assert_select "[data-gmail-grant]" do
      assert_select "time[datetime=?]", Time.current.iso8601
      assert_includes css_select("[data-gmail-grant]").sole.text, MAILBOX
      assert_includes css_select("[data-gmail-grant]").sole.text, @agent.name
    end
    assert_select "button", text: "Revoke Gmail access"
    refute_includes response.body, "synthetic-access"

    as_member do
      get conversation_connectors_path(@agent.conversation)
      assert_response :success
      refute_includes response.body, MAILBOX
      assert_select "button", text: "Revoke Gmail access", count: 0
      delete connector_sign_in_path(@connector)
      assert_response :not_found
      delete connector_path(@connector)
      assert_response :not_found
      post connector_sign_in_path(@connector)
      assert_response :not_found
      assert @connector.reload.enabled?
    end

    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
    delete connector_sign_in_path(@connector)
    assert_response :redirect
    follow_redirect!
    assert_select "[data-gmail-grant]", text: /Revoked/
    assert_nil @connector.reload.oauth_tokens
    refute @connector.enabled?
  end

  test "a refresh returning after revoke cannot restore tokens or read Gmail" do
    complete(spend(issue))
    assert_equal 200, @visitor.response.status
    travel 1.hour
    refresh = stub_request(:post, TOKEN).with(body: hash_including("grant_type" => "refresh_token")).to_return do
      delete connector_sign_in_path(@connector)
      assert_response :redirect
      { body: { access_token: "late-access", expires_in: 3600, token_type: "Bearer" }.to_json }
    end
    assert search["isError"]
    assert_requested refresh, times: 1
    assert_not_requested :any, CONTENT
    assert_nil @connector.reload.oauth_tokens
    refute @connector.enabled?
  end

  test "moving the agent revokes the grant and does not carry the named mailbox into another workspace" do
    complete(spend(issue))
    assert_equal 200, @visitor.response.status
    destination = Workspace.create!(name: "Other grant workspace")
    destination.memberships.create!(user: @owner, role: :owner)
    assert @agent.move_to(destination, by: @owner)
    assert_nil @connector.reload.oauth_tokens
    refute @connector.enabled?
    get conversation_connectors_path(@agent.conversation)
    assert_response :success
    refute_includes response.body, MAILBOX
    assert @agent.move_to(@workspace, by: @owner)
    assert_raises(McpServer::SignInNeeded) { search }
    assert_not_requested :any, CONTENT
  end

  test "only the disabled Gmail gallery connector with the install's OAuth client can be bound" do
    configs = [
      { enabled: true },
      { enabled: false, oauth_client: { "client_id" => "local-client", "client_secret" => "fake-secret" } },
      { oauth_client: nil, oauth_scope: SCOPE.split.first },
      McpServer.gallery_attributes(:calendar)
    ]
    configs.each do |changes|
      @connector.update!(changes)
      post connector_google_account_start_path(@connector), params: { expected_email: MAILBOX, agent_id: @agent.id }
      assert_response :not_found
      assert_empty @connector.google_account_starts
    end
    assert_not_requested :post, TOKEN
    assert_not_requested :get, PROFILE
  end

  private
    def as_member
      with_setting(:access, :emails, [ @owner.email, @member.email ]) do
        sign_in_via_ajent(subject: @member.oidc_sub, email: @member.email, name: @member.name)
        yield
      end
    end

    def issue
      post connector_google_account_start_path(@connector), params: { expected_email: MAILBOX, agent_id: @agent.id }
      assert_response :created
      URI(css_select("#google-account-start-link").sole["value"]).fragment
    end

    def preview(link, headers: FETCH)
      @visitor.post START, params: { start_token: link, preview: "1" }, headers: headers.merge("Accept" => "text/plain")
    end

    def preview_snapshot(link)
      queries = []
      record = ->(*event) do
        sql = event.last[:sql]
        queries << sql if sql.match?(/FROM "(?:google_account_starts|mcp_servers|agents|workspaces|users)"/)
      end
      ActiveSupport::Notifications.subscribed(record, "sql.active_record") { preview(link) }
      response = @visitor.response
      [ response.status, response.body, response.headers.except("x-request-id", "x-runtime", "date"), queries ]
    end

    def spend(link, status: 303)
      @visitor.post START, params: { start_token: link }, headers: FETCH
      assert_equal status, @visitor.response.status
      return unless status == 303

      URI.decode_www_form(URI(@visitor.response.location).query).to_h.tap do |query|
        assert_equal "install-client", query.fetch("client_id")
        assert_equal SCOPE, query.fetch("scope")
        assert_equal "http://localhost#{CALLBACK}", query.fetch("redirect_uri")
      end
    end

    def callback(query, browser: @visitor, headers: {}, **extra)
      browser.get CALLBACK, params: { state: query.fetch("state"), code: "synthetic-code", **extra }, headers: headers
    end

    def exchange_stub(query, scope: SCOPE)
      stub_request(:post, TOKEN).with { |request|
        body = URI.decode_www_form(request.body).to_h
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(body["code_verifier"].to_s), padding: false)
        body["client_id"] == "install-client" && body["client_secret"] == "synthetic-install-secret" &&
          body["redirect_uri"] == query.fetch("redirect_uri") && challenge == query.fetch("code_challenge")
      }.to_return(body: { access_token: "synthetic-access", refresh_token: "synthetic-refresh",
        expires_in: 3600, token_type: "Bearer", scope: scope }.to_json)
    end

    def profile_stub(email = MAILBOX)
      stub_request(:get, PROFILE).with(headers: { "Authorization" => "Bearer synthetic-access" }).to_return do
        yield if block_given?
        { body: { emailAddress: email }.to_json }
      end
    end

    def complete(query, email: MAILBOX, **extra)
      exchange_stub(query)
      profile_stub(email)
      callback(query, **extra)
    end

    def forbid_content
      stub_request(:any, CONTENT).to_raise(Minitest::Assertion.new("Gmail content must not be requested"))
    end

    def search(conversation = @agent.conversation)
      @connector.reload.call_tool("search_threads", {}, conversation: conversation)
    end
end
