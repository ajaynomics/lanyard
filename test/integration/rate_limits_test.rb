require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# What answers without a session is rate limited (docs/open-routes.md).
class RateLimitsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  teardown { OmniAuth.config.mock_auth[:ajent] = nil }

  test "the sign-in page and the failure page: 30 a minute per address" do
    30.times { get sign_in_path }
    assert_response :ok
    get sign_in_path
    assert_response :too_many_requests

    get sign_in_path, headers: { "REMOTE_ADDR" => "198.51.100.2" }
    assert_response :ok, "another address has its own count"
  end

  # Through the whole middleware stack: OmniAuth answers these itself, ahead of
  # any controller, so the limit must stand in front of it.
  test "Ajent's callback: 10 per 3 minutes per address, even one OmniAuth turns away itself" do
    OmniAuth.config.test_mode = false
    10.times { get "/auth/ajent/callback", params: { state: "forged", code: "x" } }
    assert_redirected_to %r{/auth/failure}
    get "/auth/ajent/callback", params: { state: "forged", code: "x" }
    assert_response :too_many_requests

    get "/auth/ajent/callback", headers: { "REMOTE_ADDR" => "198.51.100.2" }
    assert_response :redirect, "another address has its own count"
    travel 3.minutes + 1.second
    get "/auth/ajent/callback"
    assert_response :redirect
  ensure
    OmniAuth.config.test_mode = true
  end

  test "starting a sign-in: 10 per 3 minutes per address, before Ajent is asked" do
    mock_ajent_auth(email: "stranger@example.com")
    10.times { post "/auth/ajent" }
    assert_redirected_to %r{/auth/ajent/callback}
    post "/auth/ajent"
    assert_response :too_many_requests
    assert_equal "180", response.headers["Retry-After"]
  end

  test "OmniAuth's redirects are built on APP__URL, not the request's Host" do
    OmniAuth.config.test_mode = false
    get "/auth/ajent/callback", params: { state: "forged" }, headers: { "HOST" => "evil.example" }
    assert_redirected_to %r{\Ahttp://localhost/auth/failure}
  ensure
    OmniAuth.config.test_mode = true
  end

  test "Campfire's webhook: 60 a minute per token, 600 per address" do
    with_setting(:campfire, :url, "http://campfire") do
      bot = create_user.agents.sole.create_campfire_bot!(bot_key: "4-abc123")
      60.times { post campfire_webhook_path(bot.token), params: {}, as: :json }
      assert_response :no_content
      post campfire_webhook_path(bot.token), params: {}, as: :json
      assert_response :too_many_requests

      post campfire_webhook_path("guess"), params: {}, as: :json
      assert_response :not_found, "a token has its own count"
      538.times { post campfire_webhook_path("guess-#{it}"), params: {}, as: :json }
      assert_response :not_found
      post campfire_webhook_path("one-more"), params: {}, as: :json
      assert_response :too_many_requests, "guessing tokens from one address"
    end
  end

  test "voice webhook limits requests before verification" do
    60.times { post "/voice/webhooks" }
    assert_response :not_found
    post "/voice/webhooks"
    assert_response :too_many_requests
    post "/voice/webhooks", headers: { "REMOTE_ADDR" => "198.51.100.2" }
    assert_response :not_found
  end

  test "outside setup page views and redemptions have separate per-address limits" do
    30.times { get mcp_client_secret_setup_path }
    assert_response :ok
    get mcp_client_secret_setup_path
    assert_response :too_many_requests

    10.times { post mcp_client_secret_setup_path, params: { setup_token: "made-up", client_secret: "synthetic" } }
    assert_response :gone
    post mcp_client_secret_setup_path, params: { setup_token: "made-up", client_secret: "synthetic" }
    assert_response :too_many_requests
  end

  test "outside Google form, preview, claim and callback are limited separately on the canonical origin" do
    host! "localhost"
    30.times { get google_account_start_path }
    assert_response :ok
    get google_account_start_path
    assert_response :too_many_requests

    headers = { "Sec-Fetch-Site" => "same-origin", "Origin" => "null" }
    10.times do |index|
      post google_account_start_path, params: { start_token: index.to_s.rjust(40, "x"), preview: "1" }, headers: headers
      refute_equal 429, response.status
    end
    fresh = { start_token: "z" * 40, preview: "1" }
    post google_account_start_path, params: fresh, headers: headers
    assert_response :too_many_requests
    post google_account_start_path, params: fresh, headers: headers.merge("REMOTE_ADDR" => "198.51.100.2")
    refute_equal 429, response.status

    10.times { post google_account_start_path, params: { start_token: "made-up" }, headers: headers }
    assert_response :gone
    post google_account_start_path, params: { start_token: "made-up" }, headers: headers
    assert_response :too_many_requests

    30.times { get connectors_callback_path, params: { state: "gstart.#{"x" * 43}" } }
    assert_response :gone
    get connectors_callback_path, params: { state: "gstart.#{"x" * 43}" }
    assert_response :too_many_requests
  end

  test "the same preview token is limited across different addresses without blocking a different token" do
    host! "localhost"
    headers = { "Sec-Fetch-Site" => "same-origin", "Origin" => "null", "Accept" => "text/plain" }
    params = { start_token: "x" * 40, preview: "1" }
    5.times do |index|
      post google_account_start_path, params: params, headers: headers.merge("REMOTE_ADDR" => "198.51.100.#{index + 1}")
      refute_equal 429, response.status
    end
    another_address = headers.merge("REMOTE_ADDR" => "198.51.100.6")
    post google_account_start_path, params: params, headers: another_address
    assert_response :too_many_requests
    post google_account_start_path, params: params.merge(start_token: "z" * 40), headers: another_address
    refute_equal 429, response.status
  end

  test "Telegram's webhook: 60 a minute per bot, 600 per address" do
    bot = create_user.agents.sole.create_telegram_bot!(vault_entry: "Bot")
    60.times { post telegram_webhook_path(bot), params: {}, as: :json }
    assert_response :not_found, "no secret, no entry"
    post telegram_webhook_path(bot), params: {}, as: :json
    assert_response :too_many_requests

    post telegram_webhook_path(bot.id + 1), params: {}, as: :json
    assert_response :not_found, "a bot has its own count"
    538.times { post telegram_webhook_path(bot.id + 2 + it), params: {}, as: :json }
    assert_response :not_found
    post telegram_webhook_path(bot.id + 1000), params: {}, as: :json
    assert_response :too_many_requests, "guessing bots from one address"
  end
end
