require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversations::ScreensControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  UPGRADE = { "Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Version" => "13",
              "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==" }.freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
    @bot.create_computer!(provider: "sprites", state: "on")
    @conversation = create_conversation(@bot)
  end
  teardown { remove_sidecar_settings }

  test "the page shows the agent's screen through noVNC" do
    get conversation_screen_path(@conversation)

    assert_response :success
    assert_select "[data-controller=screen] [data-screen-target=display]"
    assert_select "[data-screen-target=status]", text: "Waking the computer…"
  end

  test "another person's agent has no screen here" do
    theirs = create_user(name: "Mallory").bots.sole
    theirs.create_computer!(provider: "sprites", state: "on")
    other = theirs.conversations.create!(user: theirs.user, request_id: "m", durable_id: "m")

    get conversation_screen_path(other)
    assert_response :not_found

    get conversation_screen_path(other), headers: UPGRADE.merge("Origin" => "http://www.example.com")
    assert_response :not_found
  end

  test "only an agent whose computer is a Sprite that is on has a screen" do
    @bot.computer.update!(state: "off")
    get conversation_screen_path(@conversation)
    assert_response :not_found

    @bot.computer.update!(state: "on", provider: "local")
    get conversation_screen_path(@conversation)
    assert_response :not_found
  end

  test "a websocket from another site is refused before the sidecar is asked" do
    get conversation_screen_path(@conversation), headers: UPGRADE.merge("Origin" => "https://evil.example")
    assert_response :forbidden

    get conversation_screen_path(@conversation), headers: UPGRADE
    assert_response :forbidden
  end
end
