require "application_system_test_case"

# The way in, as a person meets it in a browser: Ajent is the only door, and the
# list is asked on every click. The provider is OmniAuth's test mode here (the
# real strategy runs in test/integration/ajent_sign_in_test.rb).
class SignInTest < ApplicationSystemTestCase
  teardown { OmniAuth.config.mock_auth[:ajent] = nil }

  test "a stranger meets the sign-in page, signs in with Ajent, and signs out" do
    visit "/"

    assert_current_path "/sign_in"
    assert_text "Sign in with your Ajent account"
    mock_ajent_auth
    click_button "Sign in with Ajent"

    assert_selector "h1", text: "Durable Assistants"
    click_button "Sign out"
    assert_current_path "/sign_in"
  end

  test "an address that is not on the list is turned away at the door" do
    visit "/sign_in"
    mock_ajent_auth(email: "stranger@example.com")
    click_button "Sign in with Ajent"

    assert_current_path "/sign_in"
    assert_text "That account is not set up here."
    assert_no_selector "h1", text: "Durable Assistants"
  end

  test "taking a signed-in person off the list locks them out on their next click" do
    visit "/sign_in"
    mock_ajent_auth
    click_button "Sign in with Ajent"
    assert_selector "h1", text: "Durable Assistants"

    with_setting(:access, :emails, []) do
      visit "/"

      assert_current_path "/sign_in"
      assert_text "That account is not set up here."
    end
  end
end
