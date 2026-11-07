require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The model accounts are shared by every person's agents, so only an admin
# reaches them (ACCESS__ADMINS). To an ordinary user they do not exist, and
# nothing reaches the sidecar on their behalf.
class ModelAccountsAdminTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup { install_sidecar_settings }
  teardown { remove_sidecar_settings }

  test "an ordinary user can neither see nor change the model accounts" do
    sign_in_via_ajent(subject: "member", email: "member@example.com")

    get subscriptions_path
    assert_response :not_found
    delete subscription_path("anthropic"), params: { version: 1 }
    assert_response :not_found
    post subscription_login_path("anthropic"), params: { version: 1 }
    assert_response :not_found
    patch subscription_login_path("anthropic"), params: { login: { version: 1, id: "x", code: "y" } }
    assert_response :not_found
    patch subscription_key_path("anthropic-api"), params: { api_key: { version: 0, key: "sk-ant-api03-synthetic" } }
    assert_response :not_found
    delete subscription_key_path("anthropic-api"), params: { version: 1 }
    assert_response :not_found
    assert_not_requested :any, %r{\A#{Regexp.escape(SIDECAR)}/v1/subscriptions}
  end

  test "an ordinary user's agent page has no link to them; an admin's does" do
    sign_in_via_ajent(subject: "member", email: "member@example.com")
    agent = User.find_by!(oidc_sub: "member").agents.first # tenancy-ok: the person this test signed in
    agent.update_column(:model, "anthropic/claude-opus-5-5") # past the allowed list, which differs per install
    get agent_path(agent)
    assert_response :success
    assert_select "a[href=?]", subscriptions_path, count: 0

    with_setting(:access, :admins, %w[ member@example.com ]) do
      get agent_path(agent)
      assert_select "a[href=?]", subscriptions_path
    end
  end

  test "an admin reaches them" do
    sign_in_via_ajent
    %w[ anthropic openai-codex anthropic-api ].each do |provider|
      stub_request(:get, "#{SIDECAR}/v1/subscriptions/#{provider}")
        .to_return(body: { connected: false, configured: true, version: 0, hint: nil, pending: nil, fallback: false }.to_json)
    end
    get subscriptions_path
    assert_response :success
  end
end
