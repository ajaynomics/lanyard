require "application_system_test_case"
require_relative "../test_helpers/fake_concourse"

# Join Concourse in a real browser: the stand-in for Concourse (FakeConcourse)
# runs on this machine, the browser goes to its page and back, the agent
# waits for an owner's approval, and is connected once the page asks again.
module ConcourseJoinSetup
  extend ActiveSupport::Concern

  included do
    setup do
      sign_in_via_ajent
      @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
      @concourse = FakeConcourse.new(redirect_uri: "#{Capybara.current_session.server.base_url}/concourse/callback")
      server = Capybara::Server.new(@concourse).boot
      @settings = { concourse: Rails.application.config.x.concourse.dup, campfire: Rails.application.config.x.campfire.dup }
      Rails.application.config.x.concourse.merge!(origin: server.base_url, token_url: "#{server.base_url}/oauth/token")
      Rails.application.config.x.campfire.merge!(url: "http://campfire.example.test")
    end
    teardown do
      @settings.each { |service, settings| Rails.application.config.x.public_send(service).replace(settings) }
      OmniAuth.config.mock_auth[:ajent] = nil
    end
  end
end

class ConcourseJoinTest < ApplicationSystemTestCase
  include ConcourseJoinSetup

  test "Join, wait for approval, connected a minute after an owner admits it, and Disconnect asks first" do
    visit agent_channels_path(@agent)
    assert_selector "#concourse .ui-status", text: "Not joined"
    concourse, campfire = rect("#concourse"), rect("#campfire")
    assert_in_delta concourse["top"], campfire["top"], 1, "Concourse and Campfire sit side by side"
    assert_operator concourse["right"], :<=, campfire["left"]

    click_on "Join Concourse"

    assert_text "Assistant asked to join acme as acme/assistant."
    assert_selector "#concourse .ui-status", text: "Waiting for approval"
    assert_selector "#concourse", text: "Waiting for an owner of acme to approve acme/assistant."
    assert_equal "Assistant", @concourse.authorizations.sole["name"]

    @concourse.admit!
    travel 1.minute + 1.second
    visit agent_channels_path(@agent)
    assert_selector "#concourse .ui-status", text: "Connected"
    assert_selector "#concourse .channel__address", text: "acme/assistant"

    within("#concourse") { click_on "Disconnect" }
    within("dialog#confirm[open]") do
      assert_text "Disconnect Assistant from Concourse? Its address stops working; joining again gives it a new one."
      click_on "Disconnect"
    end
    assert_selector "#concourse .ui-status", text: "Not joined"
    assert_equal [ "acme/assistant" ], @concourse.revocations
    assert_nil @agent.reload.concourse_agent
  end

  private
    def rect(selector) = page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().toJSON()")
end

class ConcourseJoinPhoneTest < ApplicationSystemTestCase
  include ConcourseJoinSetup

  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ], options: { name: :phone } do |options|
    chromium = ENV.fetch("CHROME_BIN") { %w[/usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable].find { |path| File.executable?(path) } }
    options.binary = chromium if chromium
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_emulation(device_metrics: { width: 390, height: 844, pixelRatio: 3, touch: true })
  end

  test "on a phone, Concourse and Campfire stack, and Join is thumb-sized" do
    visit agent_channels_path(@agent)

    concourse, campfire = rect("#concourse"), rect("#campfire")
    assert_operator concourse["bottom"], :<=, campfire["top"]
    assert_operator rect("#concourse .button")["height"], :>=, 43.5
    assert_equal page.evaluate_script("innerWidth"), page.evaluate_script("document.documentElement.scrollWidth")
  end

  private
    def rect(selector) = page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().toJSON()")
end
