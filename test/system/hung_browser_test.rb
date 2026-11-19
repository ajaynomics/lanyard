require "application_system_test_case"

# A browser that stops answering costs the test it hung in, not the run. In
# CI run 8303 Chrome stopped answering partway through the suite; every later
# test then waited out the driver's timeout on each command, its failure
# screenshot included, and the job sat silent until it was killed.
class HungBrowserTest < ApplicationSystemTestCase
  # Every command waits out the driver's timeout, as Selenium's did, and fails.
  class HungDriver < Capybara::Driver::Base
    attr_reader :screenshots, :quits

    def initialize(*)
      @screenshots = @quits = 0
    end

    def visit(*) = raise(Net::ReadTimeout)
    def reset! = raise(Net::ReadTimeout)
    def save_screenshot(*, **) = @screenshots += 1
    def quit = @quits += 1
  end

  Capybara.register_driver(:hung) { |app| HungDriver.new(app) }

  test "a hung browser is quit after its test, so the next test starts a fresh one" do
    driver = nil
    hanging = Class.new(ApplicationSystemTestCase) do
      def self.name = "HangingTest"

      test "hangs" do
        Capybara.current_driver = :hung
        driver = page.driver
        visit "/"
      end
    end
    Minitest::Runnable.runnables.delete(hanging)

    # Back on this test's own browser afterwards.
    result = Capybara.using_driver(Capybara.current_driver) { hanging.new("test_hangs").run }

    assert_equal [ Net::ReadTimeout ] * 2, result.failures.map { it.error.class }, "the test and its teardown both fail"
    assert_equal 0, driver.screenshots, "a failure screenshot would wait out the timeout again"
    assert_equal 1, driver.quits, "the hung browser is let go"
  end

  test "the browser is given 30 seconds to answer a command, not Selenium's two minutes" do
    visit "/up"

    assert_equal 30, page.driver.options[:http_client].read_timeout
  end
end
