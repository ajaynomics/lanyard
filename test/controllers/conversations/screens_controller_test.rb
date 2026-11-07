require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversations::ScreensControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  UPGRADE = { "Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Version" => "13",
              "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==" }.freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @agent.create_computer!(provider: "sprites", state: "on")
    @conversation = create_conversation(@agent)
  end
  teardown { remove_sidecar_settings }

  test "the page shows the conversation's screen through noVNC" do
    get conversation_screen_path(@conversation)

    assert_response :success
    assert_select "[data-controller=screen] [data-screen-target=display]"
    assert_select "[data-screen-target=status]", text: "Waking the computer…"
  end

  test "the page says so when the computer will come back from cold storage, and otherwise that it is waking" do
    asked = stub_request(:get, "#{SIDECAR}/v1/conversations/12/computer")
      .with(query: { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s, computer: @agent.computer.name },
            headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" })
      .to_return(body: { waking: "cold" }.to_json).then
      .to_return(body: { waking: nil }.to_json).then
      .to_return(status: 503, body: { error: "computer_unavailable" }.to_json)

    get conversation_screen_path(@conversation)
    assert_select "[data-screen-target=status]", text: "Waking up, this can take a minute"

    get conversation_screen_path(@conversation)
    assert_select "[data-screen-target=status]", text: "Waking the computer…"

    # The sidecar cannot say: the page still opens, with the usual words.
    get conversation_screen_path(@conversation)
    assert_response :success
    assert_select "[data-screen-target=status]", text: "Waking the computer…"
    assert_requested asked, times: 3
  end

  test "another person's conversation has no screen here" do
    theirs = create_user(name: "Mallory").agents.sole
    theirs.create_computer!(provider: "sprites", state: "on")
    other = theirs.conversations.create!(user: theirs.user, request_id: "m", durable_id: "m")

    get conversation_screen_path(other)
    assert_response :not_found

    get conversation_screen_path(other), headers: UPGRADE.merge("Origin" => "http://www.example.com")
    assert_response :not_found
  end

  test "only a conversation whose computer is a Sprite that is on has a screen" do
    @agent.computer.update!(state: "off")
    get conversation_screen_path(@conversation)
    assert_response :not_found

    @agent.computer.update!(state: "on", provider: "local")
    get conversation_screen_path(@conversation)
    assert_response :not_found
  end

  test "a websocket from another site is refused before the sidecar is asked" do
    get conversation_screen_path(@conversation), headers: UPGRADE.merge("Origin" => "https://evil.example")
    assert_response :forbidden

    get conversation_screen_path(@conversation), headers: UPGRADE
    assert_response :forbidden
  end

  # No Access in front: the screen's websocket is held by the session cookie
  # Ajent signed the person in for, and by the Origin check. A session and the
  # site's own Origin reach the relay; the same request with every identity
  # header and no session does not.
  test "a websocket with an Ajent session and the site's Origin reaches the sidecar; identity headers alone do not" do
    reached = []
    original = Conversation.instance_method(:screen)
    computer = Class.new { def read = nil; def write(*) = nil; def flush = nil }.new
    Conversation.define_method(:screen) { |&block| reached << id; block.call(computer) }

    get conversation_screen_path(@conversation), headers: UPGRADE.merge("Origin" => "http://localhost")
    assert_equal [ @conversation.id ], reached

    reached.clear
    reset!
    get conversation_screen_path(@conversation), headers: UPGRADE.merge("Origin" => "http://localhost", "Cf-Access-Authenticated-User-Email" => "operator@example.com",
      "X-Forwarded-User" => "operator@example.com", "Remote-User" => "operator@example.com")
    assert_redirected_to sign_in_path
    assert_empty reached
  ensure
    Conversation.define_method(:screen, original)
  end
end
