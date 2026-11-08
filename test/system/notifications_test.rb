require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/push_test_helper"

# Notifications and the badge in a browser. The browser's own answers
# (permission, push service, badge) are stood in for by a script that runs
# before the page's, since a test browser has no push service to reach.
class NotificationsTest < ApplicationSystemTestCase
  include AgentTestHelper
  include PushTestHelper

  setup do
    install_sidecar_settings
    install_push_settings
    sign_in_via_ajent(name: "Robin")
    @robin = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@robin.agents.sole)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "waiting", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    @scripts = []
  end
  teardown do
    @scripts.each { page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: it) }
    remove_push_settings
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "the app's badge is the number of agents waiting on the person, set as Rails re-renders it" do
    before_each_page <<~JS
      window.badges = []
      navigator.setAppBadge = count => { window.badges.push(count); return Promise.resolve() }
      navigator.clearAppBadge = () => { window.badges.push(0); return Promise.resolve() }
    JS
    @conversation.update!(status: "waiting")
    visit conversations_path
    assert_selector "#app_badge[data-badge-count-value='1']", visible: :all
    wait_until { page.evaluate_script("window.badges.at(-1)") == 1 }
    assert_equal 1, page.evaluate_script("window.badges.at(-1)")

    # As the broadcast's replacement does, when the agent stops waiting.
    page.execute_script("document.getElementById('app_badge').dataset.badgeCountValue = '0'")
    wait_until { page.evaluate_script("window.badges.at(-1)") == 0 }
    assert_equal 0, page.evaluate_script("window.badges.at(-1)")
  end

  test "You offers notifications on this device only where the install has keys, and says when the browser blocks them" do
    before_each_page "Object.defineProperty(Notification, 'permission', { get: () => 'denied' })"
    visit settings_account_path
    assert_selector "#notifications[data-state=blocked]"
    assert_text "Notifications on this device"
    assert_text "Blocked in this browser's settings"
    assert find("#notifications_switch", visible: :all).disabled?

    with_setting(:web_push, :public_key, nil) do
      visit settings_account_path
      assert_selector "h1", text: "You"
      assert_no_text "Notifications on this device"
    end
  end

  test "the switch asks the browser, keeps this device's address, marks it in the list, and off removes it" do
    before_each_page <<~JS
      let permission = "default"
      Object.defineProperty(Notification, "permission", { get: () => permission })
      Notification.requestPermission = async () => (permission = "granted")
      let subscription = null
      const pushManager = {
        getSubscription: async () => subscription,
        subscribe: async ({ applicationServerKey }) => (subscription = {
          endpoint: "#{ENDPOINT}", keyLength: applicationServerKey.length,
          toJSON: () => ({ endpoint: "#{ENDPOINT}", keys: #{browser_keys.then { { p256dh: it[:p256dh_key], auth: it[:auth_key] } }.to_json} }),
          unsubscribe: async () => { subscription = null; return true }
        })
      }
      const registration = { pushManager }
      Object.defineProperty(navigator.serviceWorker, "ready", { get: () => Promise.resolve(registration) })
      navigator.serviceWorker.getRegistration = async () => registration
      // Kept across the page's own reloads in this test, as the browser keeps a real one.
      const saved = sessionStorage.getItem("subscribed")
      if (saved) subscription = { endpoint: saved, unsubscribe: async () => { subscription = null; sessionStorage.removeItem("subscribed"); return true } }
      if (saved) permission = "granted"
      window.addEventListener("pagehide", () => subscription ? sessionStorage.setItem("subscribed", subscription.endpoint) : sessionStorage.removeItem("subscribed"))
    JS
    visit settings_account_path
    assert_selector "#notifications[data-state=off]"
    assert_no_selector "#devices_title"

    find("label[for=notifications_switch]").click
    assert_selector "#notifications[data-state=on]"
    assert_selector "li[data-push-endpoint='#{ENDPOINT}']", text: /This device/
    assert_equal [ ENDPOINT ], @robin.push_subscriptions.pluck(:endpoint)
    assert_equal 65, page.evaluate_script("navigator.serviceWorker.ready.then(r => r.pushManager.getSubscription()).then(s => s.keyLength)"),
      "the install's public key, as the 65 bytes of a P-256 point"

    find("label[for=notifications_switch]").click
    assert_selector "#notifications[data-state=off]"
    assert_no_selector "li[data-push-endpoint]"
    assert_empty @robin.push_subscriptions.reload
  end

  test "on an iPhone outside the Home Screen, the row says to add the app there first" do
    before_each_page "Object.defineProperty(navigator, 'userAgent', { get: () => 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 Version/26.1 Mobile/15E148 Safari/604.1' })"
    visit settings_account_path
    assert_selector "#notifications[data-state=install]"
    assert_text "Add to Home Screen"
  end

  private
    # Runs before any of the page's own scripts, on every page from now on in this test.
    def before_each_page(source)
      visit "/up" if page.current_url.blank? || page.current_url == "about:blank"
      @scripts << page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: source)["identifier"]
    end
end
