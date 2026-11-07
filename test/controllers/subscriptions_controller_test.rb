require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    # The page also shows the Claude API key (Subscriptions::KeysControllerTest).
    stub_request(:get, "#{SIDECAR}/v1/subscriptions/anthropic-api").to_return(body: { configured: true, connected: false, version: 0, hint: nil }.to_json)
  end
  teardown { remove_sidecar_settings }

  def status(**overrides)
    { connected: false, version: 3, expiresAt: nil, reconnectRequired: false, failure: nil, pending: nil, fallback: false }.merge(overrides)
  end

  def stub_status(provider, **overrides)
    stub_request(:get, "#{SIDECAR}/v1/subscriptions/#{provider}").with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" })
      .to_return(body: status(**overrides).to_json)
  end

  test "the console shows both subscriptions, and nothing about it is cached" do
    stub_status("anthropic", connected: true, expiresAt: 1.day.from_now.iso8601)
    stub_status("openai-codex", version: 7)
    get subscriptions_path
    assert_response :success
    assert_select "#subscription_anthropic h2", "Claude subscription"
    assert_select "#subscription_anthropic dd", /Connected/
    assert_select "#subscription_openai_codex h2", "ChatGPT subscription"
    assert_select "#api_key_anthropic_api h2", "Claude API key"
    assert_select "#subscription_openai_codex dd", /Not connected/
    assert_select "form[action=?] input[name=version][value=7]", subscription_login_path("openai-codex")
    assert_select "form[action=?] button", subscription_login_path("openai-codex"), text: "Connect ChatGPT"
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "a server without a place for a grant says so for that subscription only" do
    stub_status("anthropic")
    stub_request(:get, "#{SIDECAR}/v1/subscriptions/openai-codex").to_return(status: 404, body: { error: "subscription_not_configured" }.to_json)
    get subscriptions_path
    assert_select "#subscription_openai_codex", /isn't set up for a ChatGPT subscription/
    assert_select "form[action=?]", subscription_login_path("openai-codex"), count: 0
    assert_select "form[action=?]", subscription_login_path("anthropic")
  end

  test "the Claude-only console's old address leads here" do
    get "/claude_subscription"
    assert_redirected_to "/subscriptions"
  end

  test "a sign-in waiting for its paste keeps its box when the page is opened again, without the link" do
    stub_status("anthropic", version: 4, pending: { id: "pending-1", expiresAt: 5.minutes.from_now.iso8601 })
    stub_status("openai-codex")
    get subscriptions_path
    assert_select "#subscription_anthropic input[name='login[id]'][value=pending-1]"
    assert_select "#subscription_anthropic input[name='login[version]'][value=4]"
    assert_select "a[href^='https://claude.ai']", count: 0
    assert_select "#subscription_anthropic button", "Start again"
  end

  test "connecting Claude: a fresh link once, then the pasted code completes that sign-in" do
    stub_status("anthropic")
    stub_status("openai-codex")
    start = stub_request(:post, "#{SIDECAR}/v1/subscriptions/anthropic/start").with(body: { version: 3 })
      .to_return(body: status(version: 4, pending: { id: "pending-1", expiresAt: 10.minutes.from_now.iso8601 }, authorizationUrl: "https://claude.ai/oauth/authorize?state=s").to_json)
    post subscription_login_path("anthropic"), params: { version: 3 }
    assert_requested start
    assert_select "a[href=?][rel~=noreferrer]", "https://claude.ai/oauth/authorize?state=s"
    assert_select "#subscription_anthropic input[name='login[id]'][value=pending-1]"
    assert_select "#subscription_anthropic input[placeholder='code#state']"
    assert_equal "same-origin", response.headers["Referrer-Policy"]

    finish = stub_request(:post, "#{SIDECAR}/v1/subscriptions/anthropic/finish").with(body: { version: 4, id: "pending-1", code: "abc#s" })
      .to_return(body: status(connected: true, version: 5).to_json)
    patch subscription_login_path("anthropic"), params: { login: { version: 4, id: "pending-1", code: "abc#s" } }
    assert_requested finish
    assert_redirected_to subscriptions_path
    assert_match "Claude subscription", flash[:notice]
  end

  test "connecting ChatGPT: the owner is told to paste the localhost address, which goes to the sidecar as pasted" do
    stub_status("anthropic")
    stub_status("openai-codex")
    stub_request(:post, "#{SIDECAR}/v1/subscriptions/openai-codex/start").with(body: { version: 3 })
      .to_return(body: status(version: 4, pending: { id: "pending-2", expiresAt: 10.minutes.from_now.iso8601 },
        authorizationUrl: "https://auth.openai.com/oauth/authorize?state=s").to_json)
    post subscription_login_path("openai-codex"), params: { version: 3 }
    assert_select "#subscription_openai_codex a[href=?]", "https://auth.openai.com/oauth/authorize?state=s", text: "Open ChatGPT's sign-in page"
    assert_select "#subscription_openai_codex li", /copy the address your browser ends up on \(it starts with http:\/\/localhost:1455\) and paste it here/
    assert_select "#subscription_openai_codex label", "Address"

    pasted = "http://localhost:1455/auth/callback?code=c&state=s"
    finish = stub_request(:post, "#{SIDECAR}/v1/subscriptions/openai-codex/finish").with(body: { version: 4, id: "pending-2", code: pasted })
      .to_return(body: status(connected: true, version: 5).to_json)
    patch subscription_login_path("openai-codex"), params: { login: { version: 4, id: "pending-2", code: pasted } }
    assert_requested finish
    assert_match "ChatGPT subscription", flash[:notice]
  end

  test "a wrong or expired paste, a change in another tab, or an unconfirmed exchange says so and starts over" do
    stub_status("openai-codex")
    { "invalid_or_expired_oauth_completion" => [ 400, /doesn't match/ ], "subscription_changed" => [ 412, /another tab/ ],
      "oauth_outcome_unconfirmed" => [ 503, /wasn't confirmed/ ] }.each do |category, (code, message)|
      stub_request(:post, "#{SIDECAR}/v1/subscriptions/openai-codex/finish").to_return(status: code, body: { error: category }.to_json)
      patch subscription_login_path("openai-codex"), params: { login: { version: 4, id: "pending-1", code: "abc#s" } }
      assert_redirected_to subscriptions_path
      assert_match message, flash[:alert]
    end
  end

  test "disconnecting names the version it saw" do
    stub_status("openai-codex", connected: true, version: 5)
    gone = stub_request(:post, "#{SIDECAR}/v1/subscriptions/openai-codex/disconnect").with(body: { version: 5 }).to_return(body: status(version: 6).to_json)
    delete subscription_path("openai-codex"), params: { version: 5 }
    assert_requested gone
    assert_redirected_to subscriptions_path
    assert_match "can't reach ChatGPT", flash[:notice]
  end

  test "only the two known subscriptions exist" do
    delete subscription_path("openai"), params: { version: 1 }
    assert_response :not_found
  end

  test "signed out, the console is not reachable" do
    delete sign_out_path
    get subscriptions_path
    assert_redirected_to sign_in_path
  end
end
