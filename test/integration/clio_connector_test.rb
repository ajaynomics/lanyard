require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# Adding Clio Manage from the gallery with the vault entry that holds its
# OAuth app, pressing Connect Clio, and coming back through the one callback:
# the sign-in is kept on the connector, encrypted, and only for the workspace
# whose person started it.
class ClioConnectorTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  TOKEN_URL = "https://app.clio.com/oauth/token".freeze

  setup do
    install_fake_passbolt(name: "Clio app", uri: "https://app.clio.com")
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
  end

  teardown { remove_fake_passbolt }

  test "added with its vault entry, it goes to Clio to sign in, and the callback keeps the tokens encrypted and lists its tools" do
    get connectors_path
    assert_select "#gallery_clio input[name='connector[vault_entry]'][required]"
    assert_select "#gallery_clio button[aria-label='Connect Clio Manage']"

    post connectors_path, params: { connector: { gallery: "clio", name: "clio", vault_entry: "Clio app" } }

    authorize = URI(response.location)
    assert_equal "https://app.clio.com/oauth/authorize", "#{authorize.scheme}://#{authorize.host}#{authorize.path}"
    query = Rack::Utils.parse_query(authorize.query)
    connector = @user.mcp_servers.sole
    assert_equal({ "response_type" => "code", "client_id" => "maya", "redirect_uri" => "http://localhost/connectors/callback",
      "state" => connector.oauth_state, "redirect_on_decline" => "true" }, query)
    assert_no_match PASSWORD, response.location
    assert_equal "Clio app", connector.vault_entry
    assert_equal "https://app.clio.com/api/v4", connector.url

    exchanged = stub_request(:post, TOKEN_URL)
      .with(body: { grant_type: "authorization_code", code: "code-4410", client_id: "maya", client_secret: PASSWORD,
        redirect_uri: "http://localhost/connectors/callback" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
        body: { access_token: "clio-access-1", refresh_token: "clio-refresh-1", token_type: "bearer", expires_in: 2_592_000 }.to_json)

    assert_enqueued_with(job: McpServerRefreshJob, args: [ connector ]) do
      get connectors_callback_path(code: "code-4410", state: query["state"])
    end
    assert_redirected_to connector_path(connector)
    assert_requested exchanged
    connector.reload
    assert connector.signed_in?
    assert_equal [ "clio-access-1", "clio-refresh-1" ], connector.oauth_tokens.values_at("access_token", "refresh_token")
    assert_nil connector.oauth_state
    stored = McpServer.connection.select_value("SELECT oauth_tokens FROM mcp_servers WHERE id = #{connector.id}") # tenancy-ok: reads the raw column
    assert_no_match "clio-refresh-1", stored, "kept encrypted"

    get connectors_callback_path(code: "code-4410", state: query["state"])
    assert_match(/doesn't match one you started/, flash[:alert])
    assert_requested exchanged, times: 1

    perform_enqueued_jobs
    get connector_path(connector)
    assert_select ".ui-group", /Runs at once.*search_matters/m
    assert_select "#asks-you-every-time + .ui-group__rows", /create_calendar_entry/
    assert_select ".ui-group", text: /Asks you first/, count: 0
    assert_select "body", text: Regexp.union("clio-access-1", "clio-refresh-1", PASSWORD), count: 0
  end

  test "a connector waiting for its sign-in offers Connect Clio; one Clio declined says so" do
    connector = @user.mcp_servers.create!(name: "clio", **McpServer.gallery_attributes(:clio), vault_entry: "Clio app")

    get connector_path(connector)
    assert_select ".settings__problem form[action='#{connector_sign_in_path(connector)}'] button", "Connect Clio"

    post connector_sign_in_path(connector)
    state = Rack::Utils.parse_query(URI(response.location).query)["state"]
    get connectors_callback_path(error: "access_denied", state: state)
    assert_redirected_to connector_path(connector)
    assert_match "Clio did not let clio in (access_denied)", flash[:alert]
    assert_not connector.reload.signed_in?
  end

  test "an entry that isn't Clio's sends nothing there, and says why" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Clio app", uri: "https://clio.example.com")

    post connectors_path, params: { connector: { gallery: "clio", name: "clio", vault_entry: "Clio app" } }

    connector = @user.mcp_servers.sole
    assert_redirected_to connector_path(connector)
    assert_match "Clio app is saved for clio.example.com, not app.clio.com", flash[:alert]
    assert_nil connector.oauth_state
  end

  test "another workspace's Clio connector can't be signed in to, nor its callback finished, from here" do
    theirs = create_user(name: "Mallory").mcp_servers.create!(name: "clio", **McpServer.gallery_attributes(:clio), vault_entry: "Clio app")
    theirs.update!(oauth_state: "their-state-1")
    token = stub_request(:post, TOKEN_URL)

    post connector_sign_in_path(theirs)
    assert_response :not_found
    get connectors_callback_path(code: "code-1", state: "their-state-1")
    assert_redirected_to connectors_path
    assert_match(/doesn't match one you started/, flash[:alert])
    assert_not_requested token
    assert_not theirs.reload.signed_in?
    assert_equal "their-state-1", theirs.oauth_state
  end

  test "without a password manager, Clio isn't offered" do
    remove_fake_passbolt
    get connectors_path
    assert_select "#gallery_clio", count: 0
  end
end
