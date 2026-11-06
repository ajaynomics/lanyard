require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  teardown { OmniAuth.config.mock_auth[:ajent] = nil }

  test "pages need a signed-in person" do
    get root_path

    assert_redirected_to sign_in_path
  end

  test "an admitted, verified Ajent account signs in and gets avery" do
    sign_in_via_ajent(email: "Operator@example.com")

    assert_equal "Avery", User.find_by!(oidc_sub: "42").bots.sole.name # tenancy-ok: test reads the person it signed in
    assert_select "h1", "Avery"
  end

  test "an address that is not admitted, or not verified, is turned away" do
    sign_in_via_ajent(email: "stranger@example.com")
    assert_select ".flash", /not set up/
    sign_in_via_ajent(email_verified: false)
    assert_select ".flash", /not set up/

    assert_equal 0, User.count # tenancy-ok: proving nobody was created
  end

  test "signing out ends the session" do
    sign_in_via_ajent
    delete sign_out_path
    get root_path

    assert_redirected_to sign_in_path
  end
end
