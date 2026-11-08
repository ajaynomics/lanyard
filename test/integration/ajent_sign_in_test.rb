require "test_helper"
require_relative "../test_helpers/fake_ajent"

# Sign-in through the real OmniAuth strategy against a fake Ajent: discovery,
# PKCE, nonce, the signed ID token and user info all run. Nothing here uses
# OmniAuth's test mode, so a mistake in the strategy's settings fails here.
class AjentSignInTest < ActionDispatch::IntegrationTest
  include FakeAjentTestHelper

  setup do
    @test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = false
    @ajent = FakeAjent.new
  end
  teardown { OmniAuth.config.test_mode = @test_mode }

  test "an admitted person with a verified email signs in and meets the starter agent, keyed by sub" do
    sign_in_through @ajent
    assert_redirected_to root_path
    follow_redirect! while response.redirect?

    user = User.find_by!(oidc_sub: "ajent-maya") # tenancy-ok: test reads the person it signed in
    assert_equal "operator@example.com", user.email
    assert_equal "Assistant", user.agents.sole.name
    assert_select "h1", "Agents"
    assert_select ".conversation-row__link", "Assistant"
  end

  test "the session cookie is httponly, lax, and expires" do
    sign_in_through @ajent

    cookie = Array(response.headers["Set-Cookie"]).flat_map(&:lines).grep(/_durable_assistants_session/).first.downcase
    assert_includes cookie, "httponly"
    assert_includes cookie, "samesite=lax"
    assert_match(/expires=/, cookie)
    assert_equal 30.days, Rails.application.config.session_options[:expire_after]
    assert_equal Rails.env.production?, Rails.application.config.session_options[:secure]
  end

  test "an email Ajent has not verified signs nobody in" do
    sign_in_through FakeAjent.new(email_verified: false)
    assert_redirected_to sign_in_path
    follow_redirect!
    assert_select ".flash", /not set up/

    assert_equal 0, User.count # tenancy-ok: proving nobody was created
  end

  test "a verified email that is not on the list signs nobody in" do
    sign_in_through FakeAjent.new(email: "stranger@example.com")
    follow_redirect!
    assert_select ".flash", /not set up/

    get root_path
    assert_redirected_to sign_in_path
    assert_equal 0, User.count # tenancy-ok: proving nobody was created
  end

  test "a person who says no at Ajent, or a forged state, is told sign-in did not complete" do
    stub_request(:any, FakeAjent::URLS).to_rack(@ajent)
    post ajent_auth_path
    get @ajent.deny(response.location)
    follow_redirect! while response.redirect?
    assert_select ".flash", "Sign-in did not complete."

    post ajent_auth_path
    callback = @ajent.approve(response.location)
    get callback.sub(/state=[^&]+/, "state=forged")
    follow_redirect! while response.redirect?
    assert_select ".flash", "Sign-in did not complete."
    assert_equal 0, User.count # tenancy-ok: proving nobody was created
  end

  test "an Ajent that cannot be reached admits nobody, and says so" do
    [ :to_timeout, [ :to_return, { status: 503 } ], [ :to_raise, SocketError ] ].each do |outage|
      stub = stub_request(:any, FakeAjent::URLS)
      outage.is_a?(Array) ? stub.public_send(outage.first, outage.last) : stub.public_send(outage)

      post ajent_auth_path
      follow_redirect!
      assert_response :service_unavailable, outage.inspect
      assert_select "h1", "Ajent isn't reachable"

      get root_path
      assert_redirected_to sign_in_path
    end
    assert_equal 0, User.count # tenancy-ok: proving nobody was created
  end

  test "an Ajent that goes down between the two halves of sign-in admits nobody" do
    stub_request(:any, FakeAjent::URLS).to_rack(@ajent)
    post ajent_auth_path
    callback = @ajent.approve(response.location)
    stub_request(:post, "https://www.example.com/oidc/token").to_return(status: 502)

    get callback
    follow_redirect!

    assert_response :service_unavailable
    assert_select "h1", "Ajent isn't reachable"
    get root_path
    assert_redirected_to sign_in_path
  end

  test "people already signed in keep working while Ajent is down: no call to it per request" do
    sign_in_through @ajent
    stub_request(:any, FakeAjent::URLS).to_timeout
    WebMock.reset_executed_requests!

    get root_path
    assert_response :success
    assert_not_requested :any, FakeAjent::URLS
  end

  test "taking someone off the list ends their session on the next request" do
    sign_in_through @ajent
    follow_redirect! while response.redirect?
    assert_response :success

    with_setting(:access, :emails, []) do
      get root_path
      assert_redirected_to sign_in_path
      follow_redirect!
      assert_select ".flash", /not set up/
    end

    get root_path
    assert_redirected_to sign_in_path, "the session itself is gone, not only refused while the list was empty"
  end

  test "someone Access signed in is claimed by their Ajent sub, and nothing they made is lost" do
    access = User.sign_in!(sub: "cloudflare-access:operator@example.com", email: "operator@example.com", name: nil)
    agent = access.agents.sole
    agent.update!(name: "Edited, since")
    conversation = agent.conversation
    connector = access.mcp_servers.create!(name: "notes", url: "https://notes.example.com/mcp")

    sign_in_through @ajent
    follow_redirect! while response.redirect?
    assert_response :success

    assert_equal 1, User.count # tenancy-ok: proving nobody was duplicated
    claimed = User.find_by!(oidc_sub: "ajent-maya") # tenancy-ok: test reads the person it signed in
    assert_equal access.id, claimed.id
    assert_equal [ agent.id ], claimed.agents.ids
    assert_equal "Edited, since", claimed.agents.sole.reload.name
    assert_equal [ conversation.id ], claimed.conversations.ids
    assert_equal [ connector.id ], claimed.mcp_servers.ids

    delete sign_out_path
    sign_in_through @ajent
    assert_equal 1, User.count, "signing in again finds the same person by sub" # tenancy-ok: proving nobody was duplicated
  end

  test "an Ajent subject that already has a row wins, and the Access row is left alone" do
    access = User.sign_in!(sub: "cloudflare-access:operator@example.com", email: "operator@example.com", name: nil)
    existing = User.sign_in!(sub: "ajent-maya", email: "someone-else@example.com", name: nil)

    sign_in_through @ajent

    assert_equal "ajent-maya", existing.reload.oidc_sub
    assert_equal "operator@example.com", existing.email
    assert_equal "cloudflare-access:operator@example.com", access.reload.oidc_sub
    assert_equal 2, User.count # tenancy-ok: proving nothing was merged or deleted
  end

  test "an email alone claims nothing: only the row Access made for it" do
    other = User.sign_in!(sub: "another-provider-sub", email: "operator@example.com", name: nil)

    sign_in_through @ajent

    assert_equal "another-provider-sub", other.reload.oidc_sub
    assert_equal 2, User.count # tenancy-ok: proving nobody was claimed by email alone
  end

  test "the sign-in page names the provider from settings, and offers no way in where none is set up" do
    get sign_in_path
    assert_select "button", "Sign in with Ajent"

    with_setting(:oidc, :name, "Acme ID") do
      get sign_in_path
      assert_select "button", "Sign in with Acme ID"
      assert_select "p", /Acme ID account/
    end

    with_setting(:oidc, :client_id, nil) do
      get sign_in_path
      assert_select "button", false
      assert_select "p", /not set up here/
    end
  end
end
