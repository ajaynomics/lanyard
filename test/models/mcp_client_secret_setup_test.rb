require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class McpClientSecretSetupTest < ActiveSupport::TestCase
  include AgentTestHelper

  SECRET = "synthetic nonfunctional client setup value"

  setup do
    @owner = create_user(name: "Owner")
    @conversation = @owner.agents.sole.conversation
    @connector = add_connector
  end

  test "one fill writes only the encrypted client field and does not start sign-in" do
    setup, token = McpClientSecretSetup.issue!(@connector, by: @owner)
    assert_not_equal token, setup.token_digest
    assert_equal setup, McpClientSecretSetup.find_by_token(token)
    assert setup.fill!(secret: SECRET)
    assert_equal SECRET, @connector.reload.oauth_client.fetch("client_secret")
    assert_equal "client_secret_post", @connector.oauth_client.fetch("token_endpoint_auth_method")
    assert_nil @connector.oauth_pending
    assert_nil @connector.oauth_tokens
    ciphertext = @connector.ciphertext_for(:oauth_client)
    assert_not_includes ciphertext, SECRET
    assert_not setup.reload.fill!(secret: "second synthetic value")
    assert_equal SECRET, @connector.reload.oauth_client.fetch("client_secret")
  end

  test "expired and superseded setups never change the connector" do
    expired, = McpClientSecretSetup.issue!(@connector, by: @owner)
    expired.update!(expires_at: 1.second.ago)
    assert_not expired.fill!(secret: SECRET)
    stale, = McpClientSecretSetup.issue!(@connector, by: @owner)
    @connector.update!(url: "https://new.example.org/mcp")
    assert_not stale.fill!(secret: SECRET)
    assert_nil @connector.reload.oauth_client["client_secret"]
  end

  test "a setup names one conversation connector and another member cannot issue for it" do
    outsider = create_user(name: "Outsider")
    setup, = McpClientSecretSetup.issue!(@connector, by: @owner)
    assert_nil McpClientSecretSetup.find_by_token("invalid")
    assert_raises(ActiveRecord::RecordNotFound) { McpClientSecretSetup.issue!(@connector, by: outsider) }
    global = add_connector(conversation: nil, name: "global")
    assert_raises(ActiveRecord::RecordNotFound) { McpClientSecretSetup.issue!(global, by: @owner) }
    other = add_connector(name: "other")
    assert setup.fill!(secret: SECRET)
    assert_nil other.reload.oauth_client["client_secret"]
  end

  test "different links do not overwrite the first secret" do
    first, = McpClientSecretSetup.issue!(@connector, by: @owner)
    second, = McpClientSecretSetup.issue!(@connector, by: @owner)
    assert first.fill!(secret: SECRET)
    assert_not second.fill!(secret: "competing synthetic value")
    assert_raises(ActiveRecord::RecordNotFound) { McpClientSecretSetup.issue!(@connector.reload, by: @owner) }
    assert_equal SECRET, @connector.reload.oauth_client.fetch("client_secret")
  end

  private
    def add_connector(conversation: @conversation, name: "example")
      @owner.personal_workspace.mcp_servers.create!(user: @owner, conversation:, url: "https://connector.example.org/mcp", name:,
        oauth_client: { "client_id" => "synthetic-public-client", "token_endpoint_auth_method" => "none" })
    end
end
