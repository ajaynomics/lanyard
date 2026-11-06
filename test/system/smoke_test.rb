require "application_system_test_case"

# The browser suite is part of bin/ci (S5), so it must have something to run
# from the first commit: a real Chrome against the Falcon the app deploys.
class SmokeTest < ApplicationSystemTestCase
  test "the app boots and answers its health check in a browser" do
    visit "/up"

    assert_selector "body"
    assert_no_text "Error"
  end
end
