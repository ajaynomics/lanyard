require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"
require_relative "../test_helpers/fake_oauth_mcp"

# Slack from the gallery with its OAuth app in the workspace's own vault: the
# client ID and secret are read from the entry the connector names, on the
# workspace's server, for each sign-in, and never kept or written to the log.
class SlackVaultConnectorTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  SLACK = %r{\Ahttps://mcp\.slack\.com/}
  # Slack's metadata names its token address on slack.com, the host the vault entry is saved for.
  TOKEN = "https://slack.com/api/oauth.v2.user.access".freeze
  ELSEWHERE = "https://evil.example.test/token".freeze
  REFUSED = "slack's sign-in server named a token address its vault entry isn't for (evil.example.test, not slack.com), so nothing was sent.".freeze
  SERVER = "https://vault.example.test".freeze
  KEY = PassboltTestHelper::PRIVATE_KEY.sub("synthetic", "household").freeze
  PASS = "household-made-up-passphrase".freeze
  CLIENT_ID = "4410.7731".freeze

  setup do
    install_fake_passbolt(name: "Household Slack app", uri: "https://slack.com", username: CLIENT_ID)
    install_fake_native_vault
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @user.personal_workspace.update!(passbolt_url: SERVER, passbolt_private_key: KEY, passbolt_passphrase: PASS)
    @fake = FakeOauthMcp.new(token_endpoint: TOKEN)
    @fake.know_client(CLIENT_ID)
    [ SLACK, %r{\Ahttps://slack\.com/}, %r{\Ahttps://evil\.example\.test/} ].each { stub_request(:any, it).to_rack(@fake) }
  end

  teardown { remove_fake_passbolt }

  test "Slack signs in with the app read from the workspace's own vault, and keeps and logs neither its ID nor its secret" do
    log = StringIO.new
    Rails.logger.broadcast_to(logger = ActiveSupport::Logger.new(log))

    get connectors_path
    assert_select "#gallery_slack input[name='connector[vault_entry]'][required]"
    assert_select "#gallery_slack input[name='connector[client_id]']", count: 0

    post connectors_path, params: { connector: { gallery: "slack", name: "slack", vault_entry: "Household Slack app" } }
    assert_equal CLIENT_ID, Rack::Utils.parse_query(URI(response.location).query)["client_id"]
    get connectors_callback_path(Rack::Utils.parse_query(URI(Rack::MockRequest.new(@fake).get(response.location).location).query))

    connector = @user.mcp_servers.sole
    assert connector.signed_in?
    assert_equal [ [ CLIENT_ID, PASSWORD ] ], @fake.token_requests.map { it.values_at("client_id", "client_secret") }
    assert_requested :post, TOKEN, times: 1
    assert_equal [ [ "vault.example.test", passbolt_user(KEY, PASS) ] ], @native_reads.uniq, "read only on the workspace's server, as its user"
    assert_empty passbolt_calls.to_s, "never on the install's"

    assert_nil connector.client_id
    assert_nil connector.client_secret
    assert_not_includes connector.oauth_client.to_h.keys, "client_id"
    assert_nil connector.oauth_pending
    database = ActiveRecord::Base.connection
    stored = database.tables.flat_map { database.select_rows("SELECT * FROM #{database.quote_table_name(it)}") }.flatten.map { it.to_s.b }.join("\n")
    decrypted = connector.attributes.to_json
    [ CLIENT_ID, PASSWORD ].each do |secret|
      assert_not stored.include?(secret.b), "#{secret} in the database"
      assert_not decrypted.include?(secret), "#{secret} on the connector"
      assert_not log.string.include?(secret), "#{secret} in the log"
    end
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "a renewal reads the app from the vault again, and keeps neither its ID nor its secret" do
    connector = signed_in_connector
    connector.update!(oauth_tokens: connector.oauth_tokens.merge("expires_at" => 1.minute.ago.to_i))
    @native_reads.clear
    @fake.token_requests.clear

    assert_equal "echo: hi", connector.call_tool("echo", { text: "hi" }).dig("content", 0, "text")
    assert_equal [ [ "refresh_token", CLIENT_ID, PASSWORD ] ], @fake.token_requests.map { it.values_at("grant_type", "client_id", "client_secret") }
    assert_requested :post, TOKEN, times: 2
    assert_equal [ "vault.example.test" ], @native_reads.map(&:first).uniq, "read again, on the workspace's server"
    assert_not_includes connector.reload.oauth_client.to_h.keys, "client_id"
    assert_not connector.attributes.to_json.include?(PASSWORD)
  end

  test "a sign-in whose server names a token address off the vault entry's host is refused by name, and nothing is sent there" do
    @fake.token_endpoint = ELSEWHERE

    post connectors_path, params: { connector: { gallery: "slack", name: "slack", vault_entry: "Household Slack app" } }
    get connectors_callback_path(Rack::Utils.parse_query(URI(Rack::MockRequest.new(@fake).get(response.location).location).query))

    assert_not_requested :any, ELSEWHERE
    assert_empty @fake.token_requests
    assert_equal REFUSED, flash[:alert]
    assert_not @user.mcp_servers.sole.signed_in?
  end

  test "a renewal whose server now names a token address off the vault entry's host is refused by name, and nothing is sent there" do
    connector = signed_in_connector
    connector.update!(oauth_tokens: connector.oauth_tokens.merge("expires_at" => 1.minute.ago.to_i))
    @fake.token_endpoint = ELSEWHERE
    @fake.token_requests.clear

    assert_equal REFUSED, assert_raises(McpServer::Unreachable) { connector.call_tool("echo", { text: "hi" }) }.message
    assert_not_requested :any, ELSEWHERE
    assert_empty @fake.token_requests
  end

  test "the refresh after the server turns a token away is refused by name too, and nothing is sent there" do
    connector = signed_in_connector
    @fake.token_endpoint = ELSEWHERE
    @fake.token_requests.clear
    @fake.expire!

    assert_equal REFUSED, assert_raises(McpServer::Unreachable) { connector.call_tool("echo", { text: "hi" }) }.message
    assert_not_requested :any, ELSEWHERE
    assert_empty @fake.token_requests
  end

  test "a workspace whose own server has lost its user refuses by name, and nothing is asked of any vault or of Slack" do
    connector = @user.mcp_servers.create!(name: "slack", **McpServer.gallery_attributes(:slack), vault_entry: "Household Slack app")
    @user.personal_workspace.update_columns(passbolt_private_key: nil, passbolt_passphrase: nil)

    post connector_sign_in_path(connector)

    assert_match "own password manager has no user set, so nothing is read from it or any other", flash[:alert]
    assert_empty Array(@native_reads)
    assert_empty passbolt_calls.to_s
    assert_not_requested :any, SLACK
  end

  test "a Slack connector with a pasted app of its own keeps signing in with it, with no vault entry" do
    connector = @user.mcp_servers.create!(name: "slack", url: "https://mcp.slack.com/mcp", client_id: "pasted-app", client_secret: "pasted-secret")
    @fake.know_client("pasted-app")

    assert_equal "pasted-app", Rack::Utils.parse_query(URI(connector.sign_in_url).query)["client_id"]
    assert_empty Array(@native_reads)
  end

  private
    def signed_in_connector
      connector = @user.mcp_servers.create!(name: "slack", **McpServer.gallery_attributes(:slack), vault_entry: "Household Slack app")
      connector.finish_sign_in(Rack::Utils.parse_query(URI(Rack::MockRequest.new(@fake).get(connector.sign_in_url).location).query))
      connector
    end
end
