require "application_system_test_case"

# Capybara's evaluate_async_script sets the browser's script timeout to its
# own two-second wait. The browser lives across tests, so a test after one
# that called it (CanvasTest's Copy) failed any script the browser took over
# two seconds to answer (CI run 10181), not thirty.
class ScriptTimeoutTest < ApplicationSystemTestCase
  test "an async script leaves the browser's script timeout as it found it, for the tests after it" do
    visit "/up"
    timeouts = page.driver.browser.manage.timeouts
    suite = timeouts.script

    assert_equal 1, page.evaluate_async_script("arguments[0](1)")

    assert_equal suite, timeouts.script
    assert_operator timeouts.script, :>, Capybara.default_max_wait_time
  end
end
