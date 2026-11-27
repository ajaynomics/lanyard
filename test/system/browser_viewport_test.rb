require "application_system_test_case"

class BrowserViewportTest < ApplicationSystemTestCase
  class PhoneSizedCase < ApplicationSystemTestCase
    def narrow_viewport
      visit "/up"
      page.current_window.resize_to(390, 844)
      assert_equal 390, page.evaluate_script("window.innerWidth")
    end
  end

  test "a phone-sized test restores the reused browser for the next test" do
    visit "/up"
    browser = page.driver.browser
    desktop_width = page.evaluate_script("window.innerWidth")
    assert_equal 1400, desktop_width

    # Run an entire case, including Rails' teardown, without depending on suite order.
    result = PhoneSizedCase.new(:narrow_viewport).run
    assert result.passed?, result.failures.map(&:message).join("\n")

    visit "/up"
    assert_same browser, page.driver.browser
    assert_equal desktop_width, page.evaluate_script("window.innerWidth")
  end
end
