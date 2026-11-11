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

  test "You offers notifications on this device where the install has keys, says when the browser blocks them, and says why not without keys" do
    before_each_page "Object.defineProperty(Notification, 'permission', { get: () => 'denied' })"
    visit settings_account_path
    assert_selector "#notifications[data-state=blocked]"
    assert_text "Notifications on this device"
    assert_text "Blocked in this browser's site settings"
    assert find("#notifications_switch", visible: :all).disabled?

    with_setting(:web_push, :public_key, nil) do
      visit settings_account_path
      assert_selector "#notifications[data-state=unconfigured]"
      assert_text "This app isn't set up to send notifications yet."
      assert_selector "#notifications .ui-row__note", text: "Not available"
      assert find("#notifications_switch", visible: :all).disabled?
    end
  end

  test "the switch asks the browser, keeps this device's address, marks it in the list, and off removes it" do
    fake_push_service
    visit settings_account_path
    assert_selector "#notifications[data-state=off]"
    assert_no_selector "#devices_title"

    find("label[for=notifications_switch]").click
    assert_selector "#notifications[data-state=on]"
    assert_selector "li[data-push-endpoint='#{ENDPOINT}']", text: /This device/
    assert_equal [ ENDPOINT ], @robin.push_subscriptions.pluck(:endpoint)
    assert_equal 65, page.evaluate_script("navigator.serviceWorker.ready.then(r => r.pushManager.getSubscription()).then(s => s.keyLength)"),
      "the install's public key, as the 65 bytes of a P-256 point"
    assert_selector "#notifications .ui-row__note", text: "On"

    stub_request(:post, ENDPOINT).to_return(status: 201)
    click_on "Send test notification"
    assert_selector "[data-notifications-target=result]", text: "Sent. It should appear in a moment"
    assert_requested :post, ENDPOINT, times: 1

    find("label[for=notifications_switch]").click
    assert_selector "#notifications[data-state=off]"
    assert_no_selector "li[data-push-endpoint]"
    assert_empty @robin.push_subscriptions.reload
  end

  test "off on this device: the kinds to notify about are greyed and kept as saved, and Turn on makes them switchable" do
    @robin.update!(push_errors: false)
    fake_push_service
    visit settings_account_path
    assert_selector "#notifications[data-state=off]"
    assert_text "Notifications are off on this device."
    assert_equal [ true, true, true ], choices.map(&:disabled?)
    assert_equal [ true, true, false ], choices.map(&:checked?), "the saved choices, shown as saved"
    assert find_button("Send test notification", disabled: true)
    assert_text "Works once notifications are on for this device."

    click_on "Turn on"
    assert_selector "#notifications[data-state=on]"
    assert_no_text "Notifications are off on this device."
    assert_equal [ false, false, false ], choices.map(&:disabled?)
    assert_equal [ true, true, false ], choices.map(&:checked?)
    assert find_button("Send test notification", disabled: false)

    find("label[for=push_messages]").click
    assert_selector ".settings__saved span", text: "Saved"
    assert_not @robin.reload.push_messages
    refresh
    assert_selector "#notifications[data-state=on]"
    assert_equal [ false, true, false ], choices.map(&:checked?)

    find("label[for=notifications_switch]").click
    assert_selector "#notifications[data-state=off]"
    assert_equal [ true, true, true ], choices.map(&:disabled?)
    assert_equal [ false, true, false ], choices.map(&:checked?), "turning off keeps the choices for turning on again"
    assert_equal [ false, true, false ], @robin.reload.then { [ it.push_messages, it.push_needs_you, it.push_errors ] }
  end

  test "blocked: the kinds and the test are greyed, and the line says where to unblock, in iOS Settings on an iPhone" do
    before_each_page "Object.defineProperty(Notification, 'permission', { get: () => 'denied' })"
    visit settings_account_path
    assert_selector "#notifications[data-state=blocked]"
    assert_selector ".notifications__reason", text: "Blocked in this browser's site settings."
    assert_no_text "iOS Settings"
    assert_equal [ true, true, true ], choices.map(&:disabled?)
    assert find_button("Send test notification", disabled: true)

    before_each_page <<~JS
      Object.defineProperty(navigator, "userAgent", { get: () => "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 Version/26.1 Mobile/15E148 Safari/604.1" })
      Object.defineProperty(navigator, "standalone", { get: () => true })
    JS
    refresh
    assert_selector "#notifications[data-state=blocked][data-apple]"
    assert_selector ".notifications__reason", text: "Blocked in iOS Settings → Notifications → #{DurableAssistants.config(:app, :name)}."
    assert_no_text "site settings"
    assert_equal [ true, true, true ], choices.map(&:disabled?)
  end

  test "on an iPhone outside the Home Screen, the row says to add the app there first" do
    before_each_page "Object.defineProperty(navigator, 'userAgent', { get: () => 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 Version/26.1 Mobile/15E148 Safari/604.1' })"
    visit settings_account_path
    assert_selector "#notifications[data-state=install]"
    assert_text "Add to Home Screen"
  end

  private
    def choices = %w[ push_messages push_needs_you push_errors ].map { find("##{it}", visible: :all) }

    # The browser's permission and its push service, stood in for: asked from a click, granted, and kept across
    # the page's own reloads in this test, as the browser keeps a real one.
    def fake_push_service
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
        const saved = sessionStorage.getItem("subscribed")
        if (saved) subscription = { endpoint: saved, unsubscribe: async () => { subscription = null; sessionStorage.removeItem("subscribed"); return true } }
        if (saved) permission = "granted"
        window.addEventListener("pagehide", () => subscription ? sessionStorage.setItem("subscribed", subscription.endpoint) : sessionStorage.removeItem("subscribed"))
      JS
    end

    # Runs before any of the page's own scripts, on every page from now on in this test.
    def before_each_page(source)
      visit "/up" if page.current_url.blank? || page.current_url == "about:blank"
      @scripts << page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: source)["identifier"]
    end
end
