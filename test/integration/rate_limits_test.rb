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
end
