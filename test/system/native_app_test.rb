require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# Pages as the phone app's web view shows them, in a real browser at a phone's
# width with the app's user agent (docs/native-app.md): no web header, the
# page's own name as its title, and nothing broken where the app lacks a
# component. Here it has none, as an older build might: every control stays
# on the page and works there. What only the app does (sheets, its bar,
# closing a sheet on refresh_historical_location) is the iOS walkthrough's
# (ios/BUILD.md, section 8).
class NativeAppTest < ApplicationSystemTestCase
  include AgentTestHelper

  APP = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 " \
        "Hotwire Native iOS; Turbo Native iOS; bridge-components: []"

  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ], options: { name: :native_app } do |options|
    chromium = ENV.fetch("CHROME_BIN") { %w[/usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable].find { |path| File.executable?(path) } }
    options.binary = chromium if chromium
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--user-agent=#{APP}")
    options.add_emulation(device_metrics: { width: 390, height: 844, pixelRatio: 3, touch: true })
  end

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/sign_in"
    click_button "Sign in with Ajent"
    # The app would close its sign-in sheet here and start its tabs afresh.
    assert_current_path "/refresh_historical_location"
    visit "/"
    assert_title "Agents"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { status: "idle", entries: [], cursor: nil, more: false }.to_json)
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/wakes}).to_return(status: 200, body: { rung: true }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "the list has no web header, its title is its own, and the app's code loads without a fault" do
    visit "/"
    assert_selector "html[data-native-app]", visible: :all
    assert_no_selector ".app-header"
    assert_equal "Agents", page.title
    assert_selector "#new_agent", text: "New agent" # no button component: the page keeps its own
    assert_equal "1", page.evaluate_script(%(String(document.styleSheets.length > 0 && [...document.styleSheets].filter(s => s.href?.includes("/native-")).length)))
    assert page.evaluate_async_script(<<~JS), "native.js should import without an error"
      const done = arguments[0]
      import("native").then(() => done(true), () => done(false))
    JS
  end

  test "without the approval or toast components a card is answered from the page, and its flash shows there" do
    payload = invocation_payload(@conversation, tool: "forget_note", arguments: { "key" => "trip" }, call_id: "call_1")
    Invocation.receive(@conversation, task_id: 7, call_id: "call_1", tool: "forget_note", arguments: payload[:arguments], digest: payload[:digest])

    visit "/approvals"
    assert_equal "Needs you", page.title
    click_on "Allow forget note?"

    assert_current_path %r{/approvals/\d+}
    click_button "Deny"

    # The app closes the sheet here and refreshes the list beneath (Hotwire Native's
    # refresh_historical_location); a browser with the app's user agent shows the path.
    assert_current_path "/refresh_historical_location"
    visit "/approvals"
    assert_selector ".flash", text: "Denied."
    assert_text "Nothing is waiting for you."
  end

  # Review, 2026-11-16: Settings and threads refresh by morphing, which kept the first answer's flash element and
  # changed its words, so its controller never connected again: the second answer showed as the web's flash, with
  # no toast and no haptic. Each answer's flash is now a new element, handed to the app every time.
  test "every answer on a page that morphs is the app's toast, with a haptic, not only the first" do
    workspace = @agent.workspace
    %w[ first second ].each { workspace.invitations.create!(email: "#{it}@example.com", inviter: @agent.user) }

    with_user_agent(APP.sub("bridge-components: []", "bridge-components: [haptic toast]")) do
      visit settings_invitations_path
      assert page.evaluate_async_script(<<~JS), "the stand-in bridge should be in place"
        const done = arguments[0]
        import("@hotwired/hotwire-native-bridge").then(() => {
          window.sentToApp = []
          window.HotwireNative.web.setAdapter({
            platform: "ios", supportedComponents: [ "haptic", "toast" ],
            supportsComponent: name => [ "haptic", "toast" ].includes(name), receive: message => window.sentToApp.push(message)
          })
          done(true)
        }, () => done(false))
      JS
      sent = -> { page.evaluate_script("window.sentToApp.map(m => [ m.component, m.event, m.data.message || m.data.feedback ])") }

      within("#invitations li", text: "first@example.com") { click_button "Approve" }
      assert_no_selector "#invitations li", text: "first@example.com"
      wait_until { sent.().count { it[1] == "show" } == 1 }
      within("#invitations li", text: "second@example.com") { click_button "Approve" }
      wait_until { sent.().count { it[1] == "show" } == 2 }

      assert_equal [ [ "haptic", "vibrate", "success" ], [ "toast", "show", "Approved first@example.com." ],
                     [ "haptic", "vibrate", "success" ], [ "toast", "show", "Approved second@example.com." ] ], sent.()
      assert_no_selector ".flash", text: "Approved second@example.com."
    end
  end

  # Review, 2026-11-16: Deny tapped in the app's bar while offline. The app greys both buttons as it answers, and the
  # page's post never arrived, so nothing ever enabled them again and the page said nothing. Now the page tells the
  # app it failed (the app enables its buttons again) and says why, and a second tap, back online, answers.
  test "an answer from the app's bar that can't be sent says so, and the app is told so it can be tried again" do
    payload = invocation_payload(@conversation, tool: "forget_note", arguments: { "key" => "trip" }, call_id: "call_1")
    Invocation.receive(@conversation, task_id: 7, call_id: "call_1", tool: "forget_note", arguments: payload[:arguments], digest: payload[:digest])
    invocation = @conversation.invocations.sole

    with_user_agent(APP.sub("bridge-components: []", "bridge-components: [approval]")) do
      visit approval_path(invocation)
      assert page.evaluate_async_script(<<~JS), "the stand-in bridge should be in place"
        const done = arguments[0]
        import("@hotwired/hotwire-native-bridge").then(() => {
          window.sentToApp = []
          window.HotwireNative.web.setAdapter({
            platform: "ios", supportedComponents: [ "approval" ],
            supportsComponent: name => name == "approval", receive: message => window.sentToApp.push(message)
          })
          done(true)
        }, () => done(false))
      JS
      tap_deny = -> { page.execute_script(<<~JS) }
        const connect = window.sentToApp.find(m => m.event == "connect")
        window.HotwireNative.web.receive({ id: connect.id, component: "approval", event: "connect", data: { choice: "deny" } })
      JS

      offline do
        tap_deny.()
        assert_selector "[role=alert]", text: "Not sent: no connection. Try again."
        assert_equal [ "connect", "failed" ], page.evaluate_script("window.sentToApp.map(m => m.event)")
      end
      assert invocation.reload.answerable?

      tap_deny.()
      assert_current_path "/refresh_historical_location"
      assert invocation.reload.denied?
    end
  end

  # The app sets the badge on the tab the page names, from the page's own component, not a notification
  # broadcast across the app (REVIEW.md finding 17); the count is the cards waiting, as Rails re-renders it.
  test "a card that starts waiting tells the app the new count and the tab it belongs on" do
    with_user_agent(APP.sub("bridge-components: []", "bridge-components: [tab-badge]")) do
      visit "/"
      assert page.evaluate_async_script(<<~JS), "the stand-in bridge should be in place"
        const done = arguments[0]
        import("@hotwired/hotwire-native-bridge").then(() => {
          window.sentToApp = []
          window.HotwireNative.web.setAdapter({
            platform: "ios", supportedComponents: [ "tab-badge" ],
            supportsComponent: name => name == "tab-badge", receive: message => window.sentToApp.push(message)
          })
          done(true)
        }, () => done(false))
      JS
      sent = -> { page.evaluate_script("window.sentToApp.filter(m => m.component == 'tab-badge').map(m => [ m.event, m.data.count, m.data.tab ])") }

      wait_for_live_updates
      @conversation.invocations.create!(task_id: "7", call_id: "c1", tool_name: "ask_person", arguments: { "question" => "Which?" },
        digest: "d", state: "awaiting_person", expires_at: 1.hour.from_now)

      # The bridge can already have the page's initial zero before the live update arrives.
      badge = [ "set", 1, "needs-you" ]
      wait_until { sent.().last == badge }
      assert_equal badge, sent.().last
    end
  end

  # The notification-token component's answer, as the app sends it after Turn on. Before, no token or a refused
  # post left the page as it was, with nothing said (TestFlight, 2026-11-15).
  test "Turn on says when the phone gave no token or the post was refused, and a token is kept" do
    visit settings_notifications_path
    retrieved = ->(token) { page.execute_script(<<~JS, token) }
      document.getElementById("native_notifications").dispatchEvent(new CustomEvent("bridge--notification-token:retrieved", { detail: { token: arguments[0] } }))
    JS

    retrieved.("")
    assert_selector "#native_notifications [role=status]", text: "The iPhone didn't turn notifications on. Check that notifications are allowed"

    retrieved.("not a token")
    assert_selector "#native_notifications [role=status]", text: "Couldn't turn on notifications here (HTTP 422)."
    # The empty token's why is the app's to say, with iOS's code (PushRegistration); the refused post's is the page's.
    assert_attempts [ [ "rejected", 422 ] ]

    retrieved.("ab" * 32)
    assert_no_selector "#native_notifications [role=status]"
    assert_equal [ "ab" * 32 ], @agent.user.push_devices.pluck(:token)
    assert_attempts [ [ "rejected", 422 ], [ "registered", nil ] ]
  end

  # Production, 2026-11-15: Turn on was tapped and no token ever came, as when iOS's permission is refused, and the
  # page said nothing. Here the app offers notification-token, and a stand-in for its bridge takes `get` and never
  # answers. The wait is cut from 15 seconds to a fraction of one. The server hears it too: before, nothing reached
  # Rails, so nobody could tell a tap that never reached the app from iOS refusing.
  test "Turn on says so when the iPhone never answers, and Rails keeps that it didn't" do
    with_apns do
      with_user_agent("NativeSignIn/1; APNs/production; Lanyard/0.1(12); " + APP.sub("bridge-components: []", "bridge-components: [notification-token]")) do
        visit settings_notifications_path
        assert page.evaluate_async_script(<<~JS), "the stand-in bridge should be in place"
          const done = arguments[0]
          import("@hotwired/hotwire-native-bridge").then(() => {
            window.sentToApp = []
            window.HotwireNative.web.setAdapter({
              platform: "ios", supportedComponents: [ "notification-token" ],
              supportsComponent: name => name == "notification-token", receive: message => window.sentToApp.push(message)
            })
            done(true)
          }, () => done(false))
        JS
        page.execute_script(%q{document.getElementById("native_notifications").setAttribute("data-native--push-device-wait-value", "300")})

        click_button "Turn on"

        assert_selector "#native_notifications [role=status]", text: "The iPhone didn't answer. Check that notifications are allowed for this app in the iPhone's Settings, then try again."
        assert_equal [ "get" ], page.evaluate_script("window.sentToApp.map(m => m.event).filter(e => e == 'get')")
        assert_attempts [ [ "no_answer", nil ] ]
        assert_equal "0.1(12)", @agent.user.push_attempts.sole.app_version
      end
    end
  end

  # A build without the notification-token component: the bridge's controller never loads. Before, Turn on was
  # hidden (native.css) and nothing said why; a tap now says so at once.
  test "Turn on says so at once when this app can't turn notifications on" do
    with_apns do
      visit settings_notifications_path
      click_button "Turn on"
      assert_selector "#native_notifications [role=status]", text: "This app can't turn notifications on: update it, then try again.", wait: 1
      assert_attempts [ [ "no_component", nil ] ]
    end
  end

  # TestFlight, 2026-11-17 (#171): two rules under the app's bar in a thread. The bar draws its own hairline
  # (AppDelegate); the thread's sticky header drew a second, its lift (layout.css), once the messages scrolled under.
  test "a thread draws no edge of its own under the app's bar, however far it scrolls" do
    40.times do |n|
      @conversation.messages.create!(entry_key: "long#{n}", entry_id: n + 10, role: n.even? ? "user" : "assistant",
        content: "Message #{n + 1}. A few words, so a phone wraps them onto more than one line of the thread.")
    end
    visit conversation_path(@conversation)
    assert_text "Message 40"

    [ 400, "document.documentElement.scrollHeight" ].each do |y|
      execute_script("scrollTo(0, #{y})")
      assert_equal "none", header_shadow, "scrolled to #{y}, the thread's header should draw no line under the app's bar"
    end
  end

  private
    # The thread header's shadow once the scroll has been drawn: its lift follows the scroll a frame later.
    def header_shadow
      page.evaluate_async_script(<<~JS)
        const done = arguments[0]
        requestAnimationFrame(() => requestAnimationFrame(() => done(getComputedStyle(document.querySelector(".chat__header")).boxShadow)))
      JS
    end

    # What Rails kept of each Turn on, once the page's post has landed.
    def assert_attempts(expected)
      attempts = -> { @agent.user.push_attempts.order(:id).pluck(:outcome, :code) }
      Timeout.timeout(Capybara.default_max_wait_time) { sleep 0.05 until attempts.() == expected }
    rescue Timeout::Error
      assert_equal expected, attempts.()
    end

    def with_apns(&block)
      { key_id: "KEY1234567", team_id: "TEAM123456", private_key: "made-up", topic: "org.example.app" }
        .reduce(block) { |inner, (key, value)| -> { with_setting(:apns, key, value, &inner) } }.call
    end

    def offline
      page.driver.browser.execute_cdp("Network.enable")
      page.driver.browser.execute_cdp("Network.emulateNetworkConditions", offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1)
      yield
    ensure
      page.driver.browser.execute_cdp("Network.emulateNetworkConditions", offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1)
    end

    def with_user_agent(agent)
      page.driver.browser.execute_cdp("Network.setUserAgentOverride", userAgent: agent)
      yield
    ensure
      page.driver.browser.execute_cdp("Network.setUserAgentOverride", userAgent: APP)
    end
end
