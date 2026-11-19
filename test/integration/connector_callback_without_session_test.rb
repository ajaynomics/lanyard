require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"
require_relative "../test_helpers/fake_oauth_mcp"

# A person sets up a connector and sends its sign-in link to someone who is not
# signed in here, a client approving their own account, say. The service sends
# that browser back to the one callback: the single-use `state` alone finishes
# the sign-in, on a plain page that names nothing, and starts no session.
class ConnectorCallbackWithoutSessionTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  OAUTH_URL = "https://oauth.example.test/mcp".freeze
  CLIO_TOKEN_URL = "https://app.clio.com/oauth/token".freeze

  setup do
    @fake = FakeOauthMcp.new
    stub_request(:any, %r{\Ahttps://oauth\.example\.test/}).to_rack(@fake)
    sign_in_via_ajent
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
  end

  teardown { remove_fake_passbolt }

  test "an OAuth connector's callback finishes from a browser with no session, once" do
    post connectors_path, params: { connector: { name: "fake", url: OAUTH_URL } }
    connector = @owner.mcp_servers.sole
    callback = URI(Rack::MockRequest.new(@fake).get(response.location).location).request_uri

    client = open_session
    assert_enqueued_with(job: McpServerRefreshJob, args: [ connector ]) { client.get callback }
    assert_connected client
    connector.reload
    assert connector.signed_in?
    assert_nil connector.oauth_state

    assert_no_enqueued_jobs { client.get callback }
    assert_refused client
  end

  test "a Clio connector's callback finishes from a browser with no session, once" do
    install_fake_passbolt(name: "Clio app", uri: "https://app.clio.com")
    post connectors_path, params: { connector: { gallery: "clio", name: "clio", vault_entry: "Clio app" } }
    connector = @owner.mcp_servers.sole
    state = Rack::Utils.parse_query(URI(response.location).query)["state"]
    exchanged = stub_request(:post, CLIO_TOKEN_URL).to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: { access_token: "clio-access-1", refresh_token: "clio-refresh-1", token_type: "bearer", expires_in: 2_592_000 }.to_json)

    client = open_session
    travel 9.minutes do
      assert_enqueued_with(job: McpServerRefreshJob, args: [ connector ]) do
        client.get connectors_callback_path(code: "code-4410", state: state)
      end
    end
    assert_connected client
    assert connector.reload.signed_in?
    assert_nil connector.oauth_state

    client.get connectors_callback_path(code: "code-4410", state: state)
    assert_refused client
    assert_requested exchanged, times: 1
  end

  test "an expired Clio state is consumed without exchanging the code" do
    install_fake_passbolt(name: "Clio app", uri: "https://app.clio.com")
    post connectors_path, params: { connector: { gallery: "clio", name: "clio", vault_entry: "Clio app" } }
    assert_clio_state_refused(@owner.mcp_servers.sole, after: 10.minutes + 1.second)
  end

  test "a Clio state issued before timestamps were stored must start again" do
    install_fake_passbolt(name: "Clio app", uri: "https://app.clio.com")
    post connectors_path, params: { connector: { gallery: "clio", name: "clio", vault_entry: "Clio app" } }
    connector = @owner.mcp_servers.sole
    connector.update!(oauth_pending: nil)
    assert_clio_state_refused(connector, after: 1.second)
  end

  test "an unknown, missing or non-text state is refused, and nothing changes" do
    post connectors_path, params: { connector: { name: "fake", url: OAUTH_URL } }
    connector = @owner.mcp_servers.sole
    state = connector.oauth_state
    query = Rack::Utils.parse_query(URI(Rack::MockRequest.new(@fake).get(response.location).location).query)

    client = open_session
    assert_no_enqueued_jobs do
      [ { code: query["code"], state: "forged" }, { code: query["code"] }, { code: query["code"], state: "" },
        { code: query["code"], state: [ state ] }, { code: query["code"], state: { x: state } } ].each do |params|
        client.get connectors_callback_path, params: params
        assert_refused client
      end
    end
    assert_not connector.reload.signed_in?
    assert_equal state, connector.oauth_state
  end

  test "a service that says no: a plain refusal, and no sign-in kept" do
    install_fake_passbolt(name: "Clio app", uri: "https://app.clio.com")
    post connectors_path, params: { connector: { gallery: "clio", name: "clio", vault_entry: "Clio app" } }
    connector = @owner.mcp_servers.sole
    state = Rack::Utils.parse_query(URI(response.location).query)["state"]
    token = stub_request(:post, CLIO_TOKEN_URL)

    client = open_session
    assert_no_enqueued_jobs { client.get connectors_callback_path(error: "access_denied", state: state) }
    assert_refused client
    assert_no_match "access_denied", client.response.body
    assert_not connector.reload.signed_in?
    assert_not_requested token
  end

  test "with no session, the callback is limited to 30 a minute per address" do
    client = open_session
    30.times { client.get connectors_callback_path(state: "forged") }
    assert_refused client
    client.get connectors_callback_path(state: "forged")
    assert_equal 429, client.response.status
    assert_private_callback client.response
  end

  # A visit would keep the address, the service's code and the state with it,
  # and leave Ahoy's cookies in a browser that is not anyone's here.
  test "with no session, the callback is not a visit" do
    track_bots, Ahoy.track_bots = Ahoy.track_bots, true
    post connectors_path, params: { connector: { name: "fake", url: OAUTH_URL } }
    callback = URI(Rack::MockRequest.new(@fake).get(response.location).location).request_uri

    client = open_session
    assert_no_difference("Ahoy::Visit.count") do # tenancy-ok: counts every visit
      client.get callback
      assert_no_callback_values_in_landing_urls callback
    end
    assert_connected client
    assert_no_match "ahoy", client.response.headers["Set-Cookie"].to_s
  ensure
    Ahoy.track_bots = track_bots
  end

  test "the signed-in callback does not store its OAuth query when the previous visit has expired" do
    track_bots, Ahoy.track_bots = Ahoy.track_bots, true
    post connectors_path, params: { connector: { name: "fake", url: OAUTH_URL } }
    connector = @owner.mcp_servers.sole
    callback = URI(Rack::MockRequest.new(@fake).get(response.location).location).request_uri
    # The sign-in cookie outlives the analytics visit cookie.
    cookies.delete("ahoy_visit")

    assert_enqueued_with(job: McpServerRefreshJob, args: [ connector ]) do
      assert_no_difference("Ahoy::Visit.count") do # tenancy-ok: counts every visit
        get callback
        assert_no_callback_values_in_landing_urls callback
      end
    end
    assert_redirected_to connector_path(connector)
    assert_private_callback response
    assert_equal @owner.id, session[:user_id]
    assert connector.reload.signed_in?
  ensure
    Ahoy.track_bots = track_bots
  end

  test "signed-in rejections redirect without caching or forwarding the callback address" do
    install_fake_passbolt(name: "Clio app", uri: "https://app.clio.com")
    post connectors_path, params: { connector: { gallery: "clio", name: "clio", vault_entry: "Clio app" } }
    connector = @owner.mcp_servers.sole

    assert_no_enqueued_jobs do
      get connectors_callback_path(code: "code-4410", state: "unknown-state")
      assert_redirected_to connectors_path
      assert_private_callback response

      get connectors_callback_path(error: "access_denied", state: connector.oauth_state)
      assert_redirected_to connector_path(connector)
      assert_private_callback response
    end
  end

  test "the callback format error keeps its address private when Rails renders the exception" do
    client = open_session
    with_public_errors { client.get connectors_callback_path(format: :json, code: "code-4410", state: "unknown-state") }

    assert_equal 500, client.response.status
    assert_private_callback client.response
  end

  test "an unexpected exception in a signed-in callback keeps its address private" do
    install_fake_passbolt(name: "Clio app", uri: "https://app.clio.com")
    post connectors_path, params: { connector: { gallery: "clio", name: "clio", vault_entry: "Clio app" } }
    connector = @owner.mcp_servers.sole
    stub_request(:post, CLIO_TOKEN_URL).to_raise(RuntimeError.new("Synthetic exchange failure"))

    with_public_errors { get connectors_callback_path(code: "code-4410", state: connector.oauth_state) }

    assert_response :internal_server_error
    assert_private_callback response
  end

  private
    def with_public_errors
      env = Rails.application.env_config
      keys = %w[ action_dispatch.show_exceptions action_dispatch.show_detailed_exceptions ]
      previous = env.slice(*keys)
      env.update(keys.zip([ :all, false ]).to_h)
      yield
    ensure
      env.update(previous)
    end

    def assert_clio_state_refused(connector, after:)
      exchanged = stub_request(:post, CLIO_TOKEN_URL).to_return(status: 200, headers: { "Content-Type" => "application/json" },
        body: { access_token: "clio-access-1", refresh_token: "clio-refresh-1" }.to_json)
      callback = connectors_callback_path(code: "code-4410", state: connector.oauth_state)
      client = open_session

      travel after do
        assert_no_enqueued_jobs { client.get callback }
      end
      assert_refused client
      assert_not connector.reload.signed_in?
      assert_nil connector.oauth_state
      assert_nil connector.oauth_pending
      assert_not_requested exchanged
    end

    def assert_no_callback_values_in_landing_urls(callback)
      query = Rack::Utils.parse_query(URI(callback).query)
      values = query.values_at("code", "state")
      assert values.all?(&:present?)
      assert_no_match Regexp.union(values), Ahoy::Visit.pluck(:landing_page).compact.join("\n") # tenancy-ok: checks every landing URL
    end

    def assert_connected(client)
      assert_equal 200, client.response.status
      assert_equal "Connected. You can close this page.", client.css_select("main").text.squish
      assert_plain client
    end

    def assert_refused(client)
      assert_equal 400, client.response.status
      assert_match "start again", client.css_select("main").text
      assert_plain client
    end

    # Names no connector, workspace or person, and leaves the browser signed out.
    def assert_plain(client)
      assert_no_match Regexp.union([ "fake", "clio", "Clio", @owner.name, @owner.email, @owner.personal_workspace.name ].compact), client.css_select("main").text
      assert_nil client.session[:user_id]
      assert_not client.response.headers["Set-Cookie"].to_s.include?("_durable_assistants_session"), "starts no session"
      assert_private_callback client.response
    end

    def assert_private_callback(response)
      assert_equal [ "no-referrer", "no-store" ], response.headers.values_at("Referrer-Policy", "Cache-Control")
    end
end
