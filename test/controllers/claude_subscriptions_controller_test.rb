require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ClaudeSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
  end
  teardown { remove_sidecar_settings }

  def status(**overrides)
    { connected: false, version: 3, expiresAt: nil, reconnectRequired: false, failure: nil, pending: nil, fallback: false }.merge(overrides)
  end

  test "the console shows the connection, and nothing about it is cached" do
    stub_request(:get, "#{SIDECAR}/v1/subscription").with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" })
      .to_return(body: status.to_json)
    get claude_subscription_path
    assert_response :success
    assert_select "dd", /Not connected/
    assert_select "form[action=?] input[name=version][value=3]", claude_subscription_login_path
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "connecting: a fresh link once, then the pasted code completes that sign-in" do
    start = stub_request(:post, "#{SIDECAR}/v1/subscription/start").with(body: { version: 3 })
      .to_return(body: status(version: 4, pending: { id: "pending-1" }, authorizationUrl: "https://claude.ai/oauth/authorize?state=s").to_json)
    post claude_subscription_login_path, params: { version: 3 }
    assert_requested start
    assert_select "a[href=?][rel~=noreferrer]", "https://claude.ai/oauth/authorize?state=s"
    assert_select "input[name='login[id]'][value=pending-1]"
    assert_equal "same-origin", response.headers["Referrer-Policy"]

    finish = stub_request(:post, "#{SIDECAR}/v1/subscription/finish").with(body: { version: 4, id: "pending-1", code: "abc#s" })
      .to_return(body: status(connected: true, version: 5).to_json)
    patch claude_subscription_login_path, params: { login: { version: 4, id: "pending-1", code: "abc#s" } }
    assert_requested finish
    assert_redirected_to claude_subscription_path
    assert_match "Connected", flash[:notice]
  end

  test "a wrong or expired code, a change in another tab, or an unconfirmed exchange says so and starts over" do
    { "invalid_or_expired_oauth_completion" => [ 400, /doesn't match/ ], "subscription_changed" => [ 412, /another tab/ ],
      "oauth_outcome_unconfirmed" => [ 503, /didn't confirm/ ] }.each do |category, (code, message)|
      stub_request(:post, "#{SIDECAR}/v1/subscription/finish").to_return(status: code, body: { error: category }.to_json)
      patch claude_subscription_login_path, params: { login: { version: 4, id: "pending-1", code: "abc#s" } }
      assert_redirected_to claude_subscription_path
      assert_match message, flash[:alert]
    end
  end

  test "disconnecting names the version it saw" do
    gone = stub_request(:post, "#{SIDECAR}/v1/subscription/disconnect").with(body: { version: 5 }).to_return(body: status(version: 6).to_json)
    delete claude_subscription_path, params: { version: 5 }
    assert_requested gone
    assert_redirected_to claude_subscription_path
  end

  test "signed out, the console is not reachable" do
    delete sign_out_path
    get claude_subscription_path
    assert_redirected_to sign_in_path
  end
end
