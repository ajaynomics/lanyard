require "test_helper"

# Rails' connection test cookie jar stands in for the encrypted session cookie,
# so these prove the rule (who is let in), not the cookie's encryption; the
# browser tests, whose pages open real connections, prove the cookie.
class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  KEY = Rails.application.config.session_options[:key]

  setup { @user = User.sign_in!(sub: "sub-1", email: "operator@example.com", name: "Operator") }

  test "a signed-in, admitted person connects" do
    cookies.encrypted[KEY] = { value: { "user_id" => @user.id } }
    connect

    assert_equal @user, connection.current_user
  end

  test "someone taken off the list can open no new connection" do
    cookies.encrypted[KEY] = { value: { "user_id" => @user.id } }

    with_setting(:access, :emails, []) { assert_reject_connection { connect } }
  end

  test "someone signed in as the install's owner is let in by their own email, not the owner's" do
    cookies.encrypted[KEY] = { value: { "user_id" => @user.id, "email" => "member@example.com" } }
    connect
    assert_equal @user, connection.current_user

    with_setting(:access, :emails, [ "operator@example.com" ]) { assert_reject_connection { connect } }
  end

  test "no session, and every identity header there is, connect nobody" do
    forged = { "Cf-Access-Authenticated-User-Email" => "operator@example.com", "X-Forwarded-User" => "operator@example.com",
               "X-Forwarded-Email" => "operator@example.com", "Remote-User" => "operator@example.com", "X-Forwarded-For" => "127.0.0.1" }

    assert_reject_connection { connect headers: forged }
    cookies[KEY] = "forged"
    assert_reject_connection { connect headers: forged }
  end
end
