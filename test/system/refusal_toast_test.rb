require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# A refusal's toast: floating over the page put it on the page's heading, across
# a phone's screen and on the heading's left at a desktop's width. It sits above
# the heading instead (#241).
class RefusalToastTest < ApplicationSystemTestCase
  include AgentTestHelper
  include McpTestHelper

  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ], options: { name: :phone } do |options|
    chromium = ENV.fetch("CHROME_BIN") { %w[/usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable].find { |path| File.executable?(path) } }
    options.binary = chromium if chromium
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_emulation(device_metrics: { width: 390, height: 844, pixelRatio: 3, touch: true })
  end

  DOCS = "http://example-docs:3000/mcp".freeze

  setup do
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = { harbor_docs: { url: DOCS, tools: %w[ search ] } }
    stub_mcp_server(url: DOCS, tools: [ mcp_tool("search") ])
    sign_in_via_ajent
    @workspace = User.find_by!(oidc_sub: "42").personal_workspace # tenancy-ok: the test reads the person it signed in
    @workspace.install_connectors.create!(name: "harbor_docs", api_key: "docs-key-made-up")
  end
  teardown do
    Rails.application.config.x.install_connectors = @previous
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "neither at a phone's width nor a desktop's does the refusal's toast cover the page's heading" do
    visit connectors_path
    assert_selector "h1", text: "Connectors"
    within("#office_connector_harbor_docs") do
      assert_button "Turn on"
      # Leave a stale button on purpose. A refresh would hide it before the test can press it.
      @workspace.install_connectors.sole.delete
      click_on "Turn on"
    end

    assert_selector ".toasts .flash[data-kind='alert']", text: "needs this workspace's own key"
    assert_selector "h1", text: "Connectors"
    assert_toast_clears_heading

    # The same toast at a desktop's width, where Settings has no bar and the toast lay on the heading's left (#241).
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 1280, height: 900, deviceScaleFactor: 1, mobile: false)
    wait_until { page.evaluate_script("innerWidth") == 1280 }
    assert_equal 1280, page.evaluate_script("innerWidth")
    assert_toast_clears_heading
  end

  private
    def assert_toast_clears_heading
      toast, heading = rect(".toasts .flash"), rect("h1")
      assert_not overlap?(toast, heading), "at #{page.evaluate_script("innerWidth")} wide the toast #{toast} covers the heading #{heading}"
    end

    def rect(selector)
      page.evaluate_script("(() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect(); " \
        "return { top: r.top, bottom: r.bottom, left: r.left, right: r.right } })()")
    end

    def overlap?(one, other)
      one["left"] < other["right"] && other["left"] < one["right"] && one["top"] < other["bottom"] && other["top"] < one["bottom"]
    end
end
