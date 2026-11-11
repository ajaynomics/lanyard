require "test_helper"

# Settings, You: the name the app calls the person. Some identity providers
# send the email as the name, so until the person sets one the app uses the
# part of their email before the @; a name they set outlasts sign-in.
class Settings::AccountsControllerTest < ActionDispatch::IntegrationTest
  test "a provider that sends the email as the name: the app says the part before the @, and You offers a name to set" do
    sign_in_via_ajent(name: "operator@example.com", email: "operator@example.com")
    robin = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    assert_equal "operator", robin.to_s
    assert_not robin.named?

    get settings_account_path
    assert_select "form[action=?][data-controller=autosave] input#user_name[name=?][placeholder=operator]:not([value])", settings_account_path, "user[name]"
    assert_select "#devices_title", count: 0
  end

  test "a name set in You is what the app says, and signing in again keeps it" do
    sign_in_via_ajent(name: "operator@example.com", email: "operator@example.com")
    robin = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in

    patch settings_account_path, params: { user: { name: "Robin" } }
    assert_redirected_to settings_account_path
    assert_equal "Robin", robin.reload.to_s
    get settings_account_path
    assert_select "input#user_name[value=Robin]"

    sign_in_via_ajent(name: "operator@example.com", email: "operator@example.com")
    assert_equal "Robin", robin.reload.name
    sign_in_via_ajent(name: "Robin Hale", email: "operator@example.com")
    assert_equal "Robin", robin.reload.name, "a name the person set outlasts the provider's"

    patch settings_account_path, params: { user: { name: "" } }
    assert_equal "operator", robin.reload.to_s, "cleared, it goes back to the part before the @"
    sign_in_via_ajent(name: "Robin Hale", email: "operator@example.com")
    assert_equal "Robin Hale", robin.reload.to_s, "with none, the provider's real name fills it"

    patch settings_account_path, params: { user: { name: "x" * (User::NAME_LIMIT + 1) } }
    assert_response :unprocessable_entity
    assert_equal "Robin Hale", robin.reload.name
  end
end
