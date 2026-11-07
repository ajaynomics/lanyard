require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A Sprite, or the sidecar, can reach kamal-proxy on the host's network and write
# any header it likes. Nothing it writes may make it somebody: the session
# cookie (which only Rails can make) is the only identity, and the sidecar's
# callbacks have their own bearer. This holds with Cloudflare Access in front
# and, with the Access path gone, with nothing in front at all.
class ForgedIdentityTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  PERSON = "operator@example.com".freeze

  FORGED = {
    "Cf-Access-Authenticated-User-Email" => PERSON, "Cf-Access-Jwt-Assertion" => "eyJhbGciOiJub25lIn0.e30.",
    "Cf-Access-Authenticated-User-Id" => "1", "X-Forwarded-User" => PERSON, "X-Forwarded-Email" => PERSON,
    "X-Forwarded-Preferred-Username" => PERSON, "X-Auth-Request-User" => PERSON, "X-Auth-Request-Email" => PERSON,
    "X-Remote-User" => PERSON, "Remote-User" => PERSON, "Remote-Email" => PERSON, "X-Authenticated-User" => PERSON,
    "X-User" => PERSON, "X-Email" => PERSON, "X-Real-IP" => "127.0.0.1", "X-Forwarded-For" => "127.0.0.1",
    "Forwarded" => "for=127.0.0.1;proto=https", "X-Forwarded-Proto" => "https", "X-Forwarded-Host" => "localhost",
    "Authorization" => "Bearer #{PERSON}", "Origin" => "http://localhost"
  }.freeze

  UPGRADE = { "Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Version" => "13",
              "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==" }.freeze

  setup do
    install_sidecar_settings
    # The person the headers claim to be is real, with a bot and a conversation,
    # so a header that were trusted would find something.
    @person = User.sign_in!(sub: "ajent-ajay", email: PERSON, name: "Ajay")
    @bot = @person.bots.sole
    @bot.create_computer!(provider: "sprites", state: "on")
    @conversation = create_conversation(@bot)
  end
  teardown { remove_sidecar_settings }

  test "identity headers, from the proxy's own network, open no page and start no session" do
    from_a_sprite = { "REMOTE_ADDR" => "192.0.2.2" }
    pages = [ [ :get, root_path ], [ :get, bot_path(@bot) ], [ :get, edit_bot_path(@bot) ], [ :get, bot_conversations_path(@bot) ],
              [ :get, conversation_path(@conversation) ], [ :get, conversation_export_path(@conversation) ],
              [ :get, conversation_screen_path(@conversation), UPGRADE ], [ :get, connectors_path ], [ :get, subscriptions_path ],
              [ :post, bot_conversations_path(@bot) ], [ :post, conversation_submissions_path(@conversation) ],
              [ :patch, bot_path(@bot) ], [ :delete, sign_out_path ] ]

    pages.each do |verb, path, extra|
      public_send(verb, path, headers: FORGED.merge(extra || {}), env: from_a_sprite)

      assert_redirected_to sign_in_path, "#{verb.upcase} #{path} must not know who the headers claim to be"
      assert_nil session[:user_id], "#{verb.upcase} #{path} started a session"
    end
    assert_equal 1, User.count, "no one was made or found by their headers" # tenancy-ok: proving nobody was created
  end

  test "the sign-in page is all a header-only visitor can see" do
    get sign_in_path, headers: FORGED

    assert_response :success
    assert_select "h1", "Avery"
    assert_nil session[:user_id]
  end

  test "the sidecar's callbacks answer only to their own bearer, whatever else a request claims" do
    forged = FORGED.except("Authorization")
    %i[ accesses invocations frames syncs ].each do |resource|
      post public_send("agent_#{resource}_path"), headers: forged
      assert_response :unauthorized, "#{resource} with no bearer"

      post public_send("agent_#{resource}_path"), headers: forged.merge("Authorization" => "Bearer #{PERSON}")
      assert_response :unauthorized, "#{resource} with a guessed bearer"

      post public_send("agent_#{resource}_path"), headers: forged.merge("Authorization" => "Bearer #{SIDECAR_TOKEN}")
      assert_response :unauthorized, "#{resource} with the sidecar's own token, which is not Rails' token"
    end
  end

  test "the control: the same pages answer a person who really signed in" do
    sign_in_via_ajent(subject: "ajent-ajay", email: PERSON)

    get bot_path(@bot)
    assert_response :success
    get conversation_path(@conversation)
    assert_response :success
  end
end
