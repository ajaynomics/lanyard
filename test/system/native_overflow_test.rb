require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# In the phone app no page scrolls sideways (#53). What is wider than the
# screen (a long link or id, a code block, a table, a picture) wraps or
# scrolls inside its own box. Every main page, light and dark, at 390 wide
# with the app's user agent; a failure names the elements that stick out, so
# the fix goes where the cause is rather than hiding the page's overflow.
class NativeOverflowTest < ApplicationSystemTestCase
  include AgentTestHelper

  APP = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 " \
        "Hotwire Native iOS; Turbo Native iOS; bridge-components: []"
  LONG_TOKEN = "x" * 160
  LONG_URL = "https://example.com/#{"path-segment-" * 12}?id=#{"0123456789abcdef" * 6}".freeze
  WIDE = <<~MARKDOWN.freeze
    A link: #{LONG_URL}

    An id: #{LONG_TOKEN}

    `#{"inline-code-" * 12}`

    ```
    #{"code = 'a very long line of code that goes on and on' + " * 6}
    ```

    | #{(1..10).map { "Column #{it}" }.join(" | ")} |
    | #{([ "---" ] * 10).join(" | ")} |
    | #{(1..10).map { "cell-#{it}-#{"wide" * 4}" }.join(" | ")} |
  MARKDOWN

  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ], options: { name: :native_overflow } do |options|
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
    assert_current_path "/refresh_historical_location"
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @agent = @user.agents.sole
    @conversation = create_conversation(@agent)
    @conversation.update!(title: "Thread #{LONG_TOKEN}")
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+(\?.*)?\z}).to_return(body: { status: "idle" }.to_json)
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/wakes}).to_return(status: 200, body: { rung: true }.to_json)
    @conversation.messages.create!(entry_key: "u1", entry_id: 1, role: "user", content: WIDE)
    @conversation.messages.create!(entry_key: "a1", entry_id: 2, role: "assistant", content: WIDE)
    @user.mcp_servers.create!(name: "wide_connector", url: LONG_URL)
    payload = invocation_payload(@conversation, tool: "forget_note", arguments: { "key" => LONG_TOKEN }, call_id: "call_1")
    Invocation.receive(@conversation, task_id: 7, call_id: "call_1", tool: "forget_note", arguments: payload[:arguments], digest: payload[:digest])
  end
  teardown { remove_sidecar_settings }

  test "no page scrolls sideways at phone width, light or dark" do
    failures = TEXT_SIZES.to_a.product(%w[ light dark ]).flat_map do |(size, pixels), scheme|
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ])
      main_pages.filter_map do |name, path|
        page.visit path # Measure the rendered page without waiting for Turbo's live streams.
        assert_selector "html[data-native-app]", visible: :all
        execute_script(DYNAMIC_TYPE, pixels)
        sleep 0.2 # images and fonts settle the layout
        wide = page.evaluate_script(WIDEST)
        "#{name} (#{size} text, #{scheme}, #{path}): page #{wide["page"]} wide in #{wide["screen"]}; #{wide["culprits"].join(", ")}" if wide["page"] > wide["screen"]
      end
    end

    assert_empty failures, "Pages scroll sideways:\n#{failures.join("\n")}"

    # The native bar owns New agent; the inline search still leaves room for the one filter menu.
    page.visit "/"
    execute_script(DYNAMIC_TYPE, 28)
    search, menu, form = evaluate_script(<<~JS)
      ['.conversation-filters__search', '.conversation-filters__menu', '.conversation-filters'].map(selector => document.querySelector(selector).getBoundingClientRect().toJSON())
    JS
    assert_operator search.fetch("right"), :<=, menu.fetch("left")
    assert_in_delta form.fetch("right"), menu.fetch("right"), 1
  end

  # iOS magnifies the page when a field under 16 pixels takes the focus, and
  # does not zoom back out: the status line and the composer's edge are then
  # past the screen's (TestFlight, 2026-11-15). Every field on a touch screen
  # is at least 16 pixels at every one of iOS's text sizes, the small ones
  # included, where 1rem is 14 or 15. The touch emulation (driven_by) is what
  # makes `pointer: coarse` match in Chromium.
  test "no field is small enough for iOS to magnify the page when it is focused" do
    assert evaluate_script("matchMedia('(pointer: coarse)').matches"), "the touch emulation should match pointer: coarse"

    failures = FIELD_TEXT_SIZES.flat_map do |pixels|
      main_pages.merge("new agent" => new_agent_path).flat_map do |name, path|
        visit path
        assert_selector "html[data-native-app]", visible: :all
        execute_script(DYNAMIC_TYPE, pixels)
        evaluate_script(SMALL_FIELDS).map { "#{name} at #{pixels}px text (#{path}): #{it}" }
      end
    end

    assert_empty failures, "Fields iOS would zoom into:\n#{failures.join("\n")}"
  end

  # The status line's longest words beside the composer, before and after the
  # composer takes the focus: they wrap, and Details stays on the screen.
  test "a thread whose cache lapsed fits the screen, before and after the composer is focused" do
    @conversation.messages.create!(entry_key: "a2", entry_id: 3, role: "assistant", content: "Done.", created_at: 2.hours.ago,
      usage: { "input" => 10, "cacheRead" => 60_000, "cacheWrite" => 43_000, "output" => 600, "totalTokens" => 103_610, "model" => "anthropic/claude-opus" })

    failures = (FIELD_TEXT_SIZES + TEXT_SIZES.values).uniq.flat_map do |pixels|
      page.visit conversation_path(@conversation)
      assert_selector ".status-line .chat__cache", text: "Cache lapsed: your next message reads all 104k tokens again."
      execute_script(DYNAMIC_TYPE, pixels)
      [ "before", "focused" ].filter_map do |moment|
        find(".composer__input").click if moment == "focused"
        sleep 0.2
        assert_equal "content", evaluate_script("document.activeElement.name") if moment == "focused"
        details = evaluate_script("document.querySelector('.status-line__details > summary').getBoundingClientRect().right")
        wide = page.evaluate_script(WIDEST)
        "#{moment} at #{pixels}px text: page #{wide["page"]} wide in #{wide["screen"]}; Details ends at #{details.round}; #{wide["culprits"].join(", ")}" if wide["page"] > wide["screen"] || details > wide["screen"]
      end
    end

    assert_empty failures, "The thread scrolls sideways:\n#{failures.join("\n")}"
  end

  # The phone's text size can change after the page has laid out: when the
  # app's web view applies it, or while a thread is open. The empty message
  # box keeps one whole line at the new size, so "Message" is not cut off.
  test "after the text size changes, the empty message box still fits its placeholder" do
    failures = TEXT_SIZES.values.filter_map do |pixels|
      visit conversation_path(@conversation)
      assert_selector ".composer__input[placeholder='Message']"
      execute_script(DYNAMIC_TYPE, pixels)
      sleep 0.2 # the new size lays out
      box = evaluate_script("(t => ({ scroll: t.scrollHeight, client: t.clientHeight }))(document.querySelector('.composer__input'))")
      "#{pixels}px text: the box shows #{box["client"]}px of its #{box["scroll"]}px" if box["scroll"] > box["client"]
    end

    assert_empty failures, "The placeholder is cut off:\n#{failures.join("\n")}"
  end

  # A thread opens at its latest message, and stays there when the text size
  # changes and the messages above grow taller.
  test "after the text size changes, the thread stays at its latest message" do
    3.times { |n| @conversation.messages.create!(entry_key: "u#{n + 3}", entry_id: n + 3, role: "user", content: "Another question #{n}. #{"Some words. " * 20}") }

    failures = TEXT_SIZES.values.filter_map do |pixels|
      visit conversation_path(@conversation)
      assert_selector "#messages > :last-child", text: "Another question 2."
      sleep 0.2 # the thread has opened at its end
      execute_script(DYNAMIC_TYPE, pixels)
      sleep 0.3 # the new size lays out
      short = evaluate_script("(s => s.scrollHeight - s.scrollTop - s.clientHeight)(document.scrollingElement)")
      "#{pixels}px text: #{short}px short of the latest message" if short > 2
    end

    assert_empty failures, "The thread left its latest message:\n#{failures.join("\n")}"
  end

  # The app's text follows the phone's text size (native.css,
  # `font: -apple-system-body`), which only Safari reads: here each of iOS's
  # body sizes is set as that font's size: the default, the largest ordinary
  # one, and the first two accessibility sizes (fonts differ between machines,
  # so the larger one keeps a margin).
  TEXT_SIZES = { "default" => 17, "largest" => 23, "accessibility" => 28, "second accessibility" => 33 }.freeze
  DYNAMIC_TYPE = "document.documentElement.style.fontSize = arguments[0] + 'px'".freeze
  # Fields at iOS's smallest body sizes too (extra small, small), where 1rem is under 16 pixels, and the default.
  FIELD_TEXT_SIZES = [ 14, 15, 17 ].freeze

  private
    def main_pages
      {
        "agents" => "/",
        "thread" => conversation_path(@conversation),
        "agent settings" => agent_path(@agent),
        "instructions" => agent_instructions_path(@agent),
        "tools" => "/agents/#{@agent.id}/tools",
        "skills" => agent_skills_path(@agent),
        "routines" => agent_routines_path(@agent),
        "channels" => agent_channels_path(@agent),
        "computer" => agent_computer_path(@agent),
        "helpers" => agent_helpers_path(@agent),
        "needs you" => approvals_path,
        "card" => approval_path(@conversation.invocations.sole),
        "connectors" => connectors_path,
        "connector" => connector_path(@user.mcp_servers.find_by!(name: "wide_connector")),
        "settings" => settings_path,
        "account" => settings_account_path,
        "notifications" => settings_notifications_path,
        "watches" => settings_watches_path,
        "documents" => conversation_documents_path(@conversation)
      }
    end

    # Each field a person can see whose text is under 16 pixels, by name and size. A submit button
    # (`input[type=submit]`, a button drawn as one) takes no typing, so iOS never zooms into it.
    SMALL_FIELDS = <<~JS.freeze
      [...document.querySelectorAll("input:not([type=submit], [type=button], [type=reset], [type=image]), textarea, select")]
        .filter(el => el.checkVisibility() && parseFloat(getComputedStyle(el).fontSize) < 16)
        .map(el => `${el.tagName.toLowerCase()}${el.type ? "[" + el.type + "]" : ""} ${el.name || el.id || el.className} ${getComputedStyle(el).fontSize}`)
    JS

    # The page's width against the screen's, and the deepest elements whose
    # right edge passes the screen's and that no box of their own scrolls.
    WIDEST = <<~JS.freeze
      (() => {
        const screen = document.documentElement.clientWidth
        const scrolls = el => { for (let p = el.parentElement; p; p = p.parentElement) {
          const x = getComputedStyle(p).overflowX; if ((x === "auto" || x === "scroll" || x === "hidden" || x === "clip") && p !== document.documentElement && p !== document.body) return true } return false }
        const out = [...document.body.querySelectorAll("*")].filter(el => {
          const r = el.getBoundingClientRect(); return r.width > 0 && r.right > screen + 1 && !scrolls(el)
        })
        const deepest = out.filter(el => !out.some(other => other !== el && el.contains(other)))
        const name = el => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") + (el.classList.length ? "." + [...el.classList].join(".") : "") + ` (${Math.round(el.getBoundingClientRect().right)})`
        // A box as wide as the page that scrolls sideways (the thread's) is the page scrolling sideways.
        const panes = [...document.body.querySelectorAll("*")].filter(el => {
          const x = getComputedStyle(el).overflowX
          return (x === "auto" || x === "scroll") && el.clientWidth >= screen * 0.8 && el.scrollWidth > el.clientWidth + 1
        })
        const inPane = pane => [...pane.querySelectorAll("*")].filter(el => el.getBoundingClientRect().right > pane.getBoundingClientRect().right + 1 && !scrollsWithin(el, pane))
        const scrollsWithin = (el, pane) => { for (let p = el.parentElement; p && p !== pane; p = p.parentElement) {
          const x = getComputedStyle(p).overflowX; if (x === "auto" || x === "scroll" || x === "hidden" || x === "clip") return true } return false }
        const paneCulprits = panes.flatMap(pane => { const o = inPane(pane); return o.filter(el => !o.some(other => other !== el && el.contains(other))).slice(0, 4) })
        const widest = Math.max(document.documentElement.scrollWidth, ...panes.map(pane => screen + pane.scrollWidth - pane.clientWidth))
        return { page: widest, screen, culprits: [...deepest, ...paneCulprits].slice(0, 6).map(name) }
      })()
    JS
end
