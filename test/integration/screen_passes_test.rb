require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A one-time link to a conversation's screen, for someone who isn't signed in
# here: a person types a code into the agent's browser from their own phone.
# The link opens on one device only, for ten minutes, until its owner ends it
# or the visitor says they're done, and reaches that screen and nothing else.
class ScreenPassesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  UPGRADE = { "Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Version" => "13",
              "Sec-WebSocket-Key" => Base64.strict_encode64("the sample nonce"), "Origin" => "http://localhost" }.freeze # RFC 6455's

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @owner.agents.sole
    @agent.create_computer!(provider: "sprites", state: "on")
    @conversation = create_conversation(@agent)
    @reached = []
    @original = Conversation.instance_method(:screen)
    reached, computer = @reached, Class.new { def read = nil; def write(*) = nil; def flush = nil }.new
    Conversation.define_method(:screen) { |&block| reached << id; block.call(computer) }
  end

  teardown do
    Conversation.define_method(:screen, @original)
    remove_sidecar_settings
  end

  test "the owner makes a link on the screen page, shown once, and the screen page offers it" do
    get conversation_screen_path(@conversation)
    assert_select "form[action='#{conversation_screen_passes_path(@conversation)}'] button", text: "Share this screen"

    link = share
    assert_match %r{\Ahttp://[^/]+/screen_passes/[A-Za-z0-9]{32,}\z}, link
    pass = @conversation.screen_passes.sole
    assert_equal @owner, pass.created_by
    assert_in_delta 10.minutes.from_now, pass.expires_at, 5
    assert_not_includes pass.attributes.to_json, link.split("/").last, "only its digest is kept"

    get conversation_screen_path(@conversation)
    assert_not_includes response.body, link, "the link is never shown again"
    assert_select ".screen-share", text: /open until/
  end

  test "opened without a sign-in it shows the screen and relays only to that conversation's computer" do
    link = share
    as_visitor do
      get link
      assert_response :success
      assert_select "[data-controller=screen] [data-screen-target=display]"
      assert_select "form[action='#{URI(link).path}'] button", text: "Done"

      get link, headers: UPGRADE
      assert_equal [ @conversation.id ], @reached

      get conversation_path(@conversation)
      assert_redirected_to sign_in_path, "the link reaches the screen and nothing else"
      get conversation_screen_path(@conversation), headers: UPGRADE
      assert_redirected_to sign_in_path
    end
  end

  test "it opens on one device only: the same phone may reload, another is refused, before and after" do
    link = share
    as_visitor do
      get link
      get link
      assert_response :success
    end
    as_visitor do
      get link
      assert_response :gone
      assert_match "already been opened on another device", response.body
      get link, headers: UPGRADE
      assert_response :not_found
    end
    assert_equal 0, @reached.size
  end

  test "after ten minutes it is over: the page and its websocket are refused" do
    link = share
    as_visitor do
      get link
      travel 10.minutes + 1.second
      get link
      assert_response :gone
      assert_match "expired", response.body
      get link, headers: UPGRADE
      assert_response :not_found
    end
    as_visitor do
      get link
      assert_response :gone
    end
    assert_empty @reached
  end

  test "ended by its owner, or by the visitor's Done, it opens no more" do
    first = share
    as_visitor { get first }
    delete conversation_screen_pass_path(@conversation, @conversation.screen_passes.sole)
    assert_redirected_to conversation_screen_path(@conversation)
    as_visitor do
      get first
      assert_response :gone
      assert_match "ended", response.body
    end

    second = share
    as_visitor do
      get second
      delete URI(second).path
      assert_response :success
      assert_match "Thanks", response.body
      get second
      assert_response :gone
      get second, headers: UPGRADE
      assert_response :not_found
    end
    assert_empty @reached
  end

  # As production checks forgery. A browser posts a form with Origin "null"
  # from a page sent with Referrer-Policy no-referrer, which Rails refuses:
  # the visitor's Done would fail. same-origin still sends the link's address
  # to no other site.
  test "Done goes through with forgery protection on, from a page whose policy lets the browser name its origin" do
    link = share
    as_visitor do
      with_forgery_protection do
        get link
        assert_equal "same-origin", response.headers["Referrer-Policy"]
        # What one sends under no-referrer, refused, as the browser pass found.
        delete URI(link).path, headers: { "Origin" => "null" }
        assert_response :unprocessable_content
        # What a browser sends from that page: its own site, by name.
        delete URI(link).path, headers: { "Sec-Fetch-Site" => "same-origin", "Origin" => "http://www.example.com" }
        assert_response :success
        assert_match "Thanks", response.body
      end
    end
  end

  test "a websocket needs the device that opened it and the site's own Origin" do
    link = share
    as_visitor do
      get link, headers: UPGRADE
      assert_response :not_found, "no page opened on this device first"
    end
    as_visitor do
      get link
      get link, headers: UPGRADE.merge("Origin" => "https://evil.example")
      assert_response :forbidden
    end
    assert_empty @reached
  end

  test "an unknown or malformed link is not found, and the address is limited to 30 a minute" do
    as_visitor do
      get "/screen_passes/#{"x" * 40}"
      assert_response :not_found
      29.times { get "/screen_passes/nope" }
      get "/screen_passes/nope"
      assert_response :too_many_requests
    end
  end

  test "only a conversation of the person's workspace with a screen can be shared" do
    theirs = create_user(name: "Mallory").agents.sole
    theirs.create_computer!(provider: "sprites", state: "on")
    other = create_conversation(theirs, durable_id: "m")
    post conversation_screen_passes_path(other)
    assert_response :not_found

    @agent.computer.update!(state: "off")
    post conversation_screen_passes_path(@conversation)
    assert_response :not_found
    assert_equal 0, ScreenPass.count # tenancy-ok: counts every pass the test made
  end

  test "while an operator holds the computer the visitor's websocket is refused before the sidecar is asked" do
    link = share
    as_visitor do
      get link
      @agent.computer.hold!
      get link, headers: UPGRADE
      assert_response :service_unavailable
    end
    assert_empty @reached
  end

  private
    # The link, as the owner's page shows it once.
    def share
      post conversation_screen_passes_path(@conversation), as: :turbo_stream
      assert_response :success
      response.body[%r{name="screen_link" value="([^"]+)"}, 1]
    end

    def with_forgery_protection
      was, ActionController::Base.allow_forgery_protection = ActionController::Base.allow_forgery_protection, true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = was
    end

    # Another browser: no session of the owner's, its own cookies.
    def as_visitor
      saved = cookies.to_hash
      reset!
      yield
    ensure
      reset!
      saved.each { |name, value| cookies[name] = value }
    end
end
