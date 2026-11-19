require "test_helper"

# Capybara's default server is Puma. This app is Falcon, so the browser tests
# drive the server production runs.
Capybara.register_server :falcon do |app, port, host|
  require "rackup/handler/falcon"
  Rackup::Handler::Falcon.run(app, Host: host, Port: port)
end
Capybara.server = :falcon

# This machine's Chromium is /usr/bin/chromium; CI's comes from setup-chrome,
# which says where it put Chrome and its driver (CHROME_BIN, CHROMEDRIVER_PATH).
# Naming the driver stops Selenium Manager reaching for the network to find one.
driver = ENV.fetch("CHROMEDRIVER_PATH") { %w[/usr/bin/chromedriver /usr/local/bin/chromedriver].find { |path| File.executable?(path) } }
Selenium::WebDriver::Chrome::Service.driver_path = driver if driver

# A Turbo refresh replaces the page while Capybara is checking an element, and
# Chrome says so with an "unknown error" ("Node with given id does not belong
# to the document") that Capybara does not know to retry. It is a stale
# element, so Selenium is told to report it as one and Capybara retries.
module DetachedNodeIsStale
  MESSAGE = "does not belong to the document"

  def error
    found = super
    return found unless found.is_a?(Selenium::WebDriver::Error::UnknownError) && found.message.to_s.include?(MESSAGE)
    Selenium::WebDriver::Error::StaleElementReferenceError.new(found.message)
  end
end
Selenium::WebDriver::Remote::Response.prepend(DetachedNodeIsStale)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # One browser at a time, as when there were fewer than Rails' threshold of
  # 50 of these: past it, every test got its own Chrome at once, and on a busy
  # machine unrelated ones failed by chance (a click that landed mid-visit).
  parallelize(workers: 1)

  # Selenium waits two minutes for each answer from the browser. One that has
  # stopped answering answers nothing again, so a shorter wait bounds what it
  # costs before it is let go (after_teardown).
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: { timeout: 30 } do |options|
    chromium = ENV.fetch("CHROME_BIN") { %w[/usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable].find { |path| File.executable?(path) } }
    options.binary = chromium if chromium
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end

  include OmniAuthTestHelper

  # The app's public address is the test server's, as APP__URL is the real one's:
  # OmniAuth builds its redirects on it.
  setup do
    @app_url = Rails.application.config.x.app[:url]
    Rails.application.config.x.app[:url] = Capybara.current_session.server.base_url
  end
  teardown { Rails.application.config.x.app[:url] = @app_url }

  # A test can end while its last request is still being answered (one that
  # checks what reached the sidecar, say). Capybara clears the browser's
  # cookies first, then that answer's session cookie arrives, and the next
  # test starts signed in as someone the rollback removed (#61). The answer
  # comes first; Capybara's reset follows in super.
  #
  # A browser that stopped answering is let go, so the next test starts a
  # fresh one rather than waiting it out on every command (CI run 8303).
  def after_teardown
    Capybara.current_session.server&.wait_for_pending_requests
    super
  rescue Net::ReadTimeout
    quit_browser
    raise
  end

  # Asking a browser that stopped answering for a picture only waits again.
  def take_failed_screenshot
    super unless failures.any? { it.error.is_a?(Net::ReadTimeout) }
  end

  # The page shows a message the moment it is sent, before the request
  # reaches the server: a test that checks the request waits for it.
  # A change shown by broadcast alone (Message, Cancel) is missed if the page's
  # streams are not connected yet when it is pressed.
  def wait_for_live_updates = assert_no_selector("turbo-cable-stream-source:not([connected])", visible: :all)

  def wait_until(seconds = Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def sign_in_via_ajent(**options)
    mock_ajent_auth(**options)
    visit "/auth/ajent/callback"
  end

  private
    # Quitting asks the hung browser to close, which times out too, though by
    # then Capybara has dropped it and stopped its driver. The second quit,
    # with no browser left to ask, clears the session.
    def quit_browser
      Capybara.current_session.quit
    rescue Net::ReadTimeout
      Capybara.current_session.quit
    end
end
