require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"
require_relative "../../test_helpers/fake_oauth_mcp"

# Slack's app lives in the workspace's vault, but the token a sign-in earns
# rotates on every renewal, so it is kept on the connector, encrypted, and
# renewed by one call at a time (McpServer::Renewal): two calls that find it
# expired at once send one refresh. Slack turns away a refresh token used
# twice, so a second refresh would cost the sign-in.
class McpServer::VaultAppRenewalTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PassboltTestHelper

  # Fixture transactions would share one connection between the two calls,
  # and hold the very lock this test is about.
  self.use_transactional_tests = false

  SLACK = %r{\Ahttps://mcp\.slack\.com/}
  # Slack's metadata names its token address on slack.com, the host the vault entry is saved for.
  TOKEN = "https://slack.com/api/oauth.v2.user.access".freeze
  ELSEWHERE = "https://evil.example.test/token".freeze
  REFUSED = "slack's sign-in server named a token address its vault entry isn't for (evil.example.test, not slack.com), so nothing was sent.".freeze
  KEY = PassboltTestHelper::PRIVATE_KEY.sub("synthetic", "household").freeze
  PASS = "household-made-up-passphrase".freeze
  CLIENT_ID = "4410.7731".freeze

  setup do
    @saved = ActiveRecord::Base.connection_db_config
    @path = Rails.root.join("tmp/vault-app-renewal-#{Process.pid}.sqlite3").to_s
    primary = ActiveRecord::Base.configurations.configs_for(env_name: "production", name: "primary")
    config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", primary.configuration_hash.merge(database: @path))
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) { load Rails.root.join("db/schema.rb") }
    end
    ActiveRecord::Base.establish_connection(config)

    install_fake_passbolt(name: "Household Slack app", uri: "https://slack.com", username: CLIENT_ID)
    install_fake_native_vault
    user = create_user
    user.personal_workspace.update!(passbolt_url: "https://vault.example.test", passbolt_private_key: KEY, passbolt_passphrase: PASS)
    @fake = FakeOauthMcp.new(token_endpoint: TOKEN)
    @fake.know_client(CLIENT_ID)
    # A refresh that takes a moment, so the second call arrives while the first is still waiting on Slack.
    slack = ->(env) { sleep 0.5 if env["PATH_INFO"] == URI(TOKEN).path && @signed_in; @fake.call(env) }
    [ SLACK, %r{\Ahttps://slack\.com/}, %r{\Ahttps://evil\.example\.test/} ].each { stub_request(:any, it).to_rack(slack) }

    @connector = user.mcp_servers.create!(name: "slack", **McpServer.gallery_attributes(:slack), vault_entry: "Household Slack app")
    @connector.finish_sign_in(Rack::Utils.parse_query(URI(Rack::MockRequest.new(@fake).get(@connector.sign_in_url).location).query))
    @signed_in = true
    @connector.update!(oauth_tokens: @connector.oauth_tokens.merge("expires_at" => 1.minute.ago.to_i))
    @expired = @connector.oauth_tokens
    @fake.token_requests.clear
    File.write(@passbolt_calls, "")
  end

  teardown do
    remove_fake_passbolt
    ActiveRecord::Base.establish_connection(@saved)
    FileUtils.rm_f(Dir["#{@path}*"])
  end

  test "two calls that find the token expired send one refresh; the other uses its token or is told to try again; kept encrypted and never in the vault" do
    calls = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          server = McpServer.find(@connector.id) # tenancy-ok: the test's own connector, read afresh as a second request would
          server.call_tool("echo", { text: "hi" })
          server.oauth_tokens["access_token"]
        rescue McpServer::Renewing => problem
          problem.message
        end
      end
    end.map(&:value)

    assert_equal 1, @fake.token_requests.count { it["grant_type"] == "refresh_token" }, "one refresh, not one per call"
    renewed = @connector.reload.oauth_tokens
    assert_not_equal @expired["access_token"], renewed["access_token"]
    assert_includes calls, renewed["access_token"]
    assert_empty calls - [ renewed["access_token"], "slack's sign-in is being renewed; try again in a few seconds." ]

    stored = McpServer.connection.select_value("SELECT oauth_tokens FROM mcp_servers WHERE id = #{@connector.id}")
    assert_equal %w[ h p ], JSON.parse(stored).keys.sort, "kept as ciphertext"
    [ renewed["access_token"], renewed["refresh_token"] ].each { assert_not_includes stored, it }

    assert_operator @native_reads.size, :>=, 1, "the app is read from the vault for the refresh"
    assert_empty passbolt_calls, "nothing is saved to the vault: passbolt-save never runs"
  end

  test "a renewal whose server now names a token address off the vault entry's host is refused by name, sends nothing there and lets the claim go" do
    @fake.token_endpoint = ELSEWHERE

    problem = assert_raises(McpServer::Unreachable) { @connector.call_tool("echo", { text: "hi" }) }
    assert_not_requested :any, ELSEWHERE
    assert_empty @fake.token_requests
    assert_equal REFUSED, problem.message
    assert_nil @connector.reload.refresh_claim, "the token never left, so the next renewal may send it"
  end

  test "the refresh after Slack turns a token away is refused by name too, and sends nothing there" do
    @connector.update!(oauth_tokens: @expired.merge("expires_at" => 1.hour.from_now.to_i))
    @fake.expire!
    @fake.token_endpoint = ELSEWHERE

    problem = assert_raises(McpServer::Unreachable) { @connector.call_tool("echo", { text: "hi" }) }
    assert_not_requested :any, ELSEWHERE
    assert_empty @fake.token_requests
    assert_equal REFUSED, problem.message
    assert_nil @connector.reload.refresh_claim
  end
end
