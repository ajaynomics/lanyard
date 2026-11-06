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

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    chromium = ENV.fetch("CHROME_BIN") { %w[/usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable].find { |path| File.executable?(path) } }
    options.binary = chromium if chromium
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end

  include OmniAuthTestHelper

  def sign_in_via_ajent(**options)
    mock_ajent_auth(**options)
    visit "/auth/ajent/callback"
  end
end
