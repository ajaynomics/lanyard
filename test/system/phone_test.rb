require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# People use the app from their phones: every screen fits 390 px
# without sideways scrolling, and what a thumb presses is about 44 px.
class PhoneTest < ApplicationSystemTestCase
  include AgentTestHelper
  include EmailTestHelper
  include McpTestHelper

  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ], options: { name: :phone } do |options|
    chromium = ENV.fetch("CHROME_BIN") { %w[/usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable].find { |path| File.executable?(path) } }
    options.binary = chromium if chromium
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    # A phone: its width, and a finger for a pointer.
    options.add_emulation(device_metrics: { width: 390, height: 844, pixelRatio: 3, touch: true })
  end

  LONG = "https://example.com/a/very/long/address/that/has/no/place/to/break/at/all/on/a/phone/screen"

  setup do
    install_sidecar_settings
    install_email_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    @agent.routines.create!(schedule: "every day at 8am", prompt: "Check the weather and say if I need an umbrella.")
    ask("ask_person", { "question" => "Tea or coffee?", "options" => %w[ Tea Coffee ] }, "call_1")
    ask("send_email", { "to" => [ "someone@outside.example" ], "subject" => "Booking", "body" => "Please confirm Friday. #{LONG}" }, "call_2")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(body: { status: "waiting", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(body: { models: [] }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/subscriptions/}).to_return(body: { connected: false, version: 1 }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [
      { id: "1", entryId: 1, role: "user", content: "Email the hotel about #{LONG}" },
      { id: "2", entryId: 2, role: "assistant", toolCalls: [ { id: "call_1", name: "ask_person" }, { id: "call_2", name: "send_email" } ],
        content: "**Sure.**\n\n```\na_line_of_code_much_too_long_for_a_phone = call(argument_one, argument_two, argument_three)\n```\n\n| when | where | who |\n|---|---|---|\n| Friday evening | the hotel on the hill | everyone |" }
    ], cursor: 2, more: false }.to_json)
  end

  teardown do
    remove_sidecar_settings
    remove_email_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "an agent's thread fits the screen: long words wrap, code and tables scroll inside, the composer stays in view" do
    visit conversation_path(@conversation)
    assert_selector ".ui-card__title", text: "Allow send email?"
    assert_fits_width
    assert_thumb_sized ".question__option", ".ui-card__actions .button", ".composer__send", ".composer__attach", ".chat-panel__open"

    composer = rect("#composer")
    assert_operator composer["bottom"], :<=, viewport_height, "the composer is below the screen"
    assert_operator rect("#composer textarea")["width"], :>=, 180, "the message box is squeezed"
  end

  test "the send arrow is there only with something to send; while the agent works, a square stops it, and Steer and Queue leave room to type" do
    visit conversation_path(@conversation)
    assert_no_button "Send"
    find("#composer textarea").send_keys("Hi")
    assert_button "Send"
    assert_thumb_sized ".composer__send"

    @conversation.update!(status: "running")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(body: { status: "running", failure: nil, pendingInputs: [] }.to_json)
    visit conversation_path(@conversation)
    find("#composer textarea").set("")
    assert_selector ".composer__stop", visible: true
    assert_no_button "Steer"
    assert_thumb_sized ".composer__stop"

    find("#composer textarea").send_keys("Also this")
    assert_no_selector ".composer__stop", visible: true
    assert_selector ".composer__steer", visible: true
    assert_fits_width
    assert_operator rect("#composer textarea")["width"], :>=, rect("#composer")["width"] * 0.45, "the message box is squeezed"
    assert_thumb_sized ".composer__steer", ".composer__send"
  end

  # As in Messages: a phone's Return is for lines; Send sends. A computer's Enter still sends (ConversationTest).
  test "on a phone Return makes a new line, twice too, and only Send sends" do
    sent = nil
    submit = stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").with { sent = JSON.parse(it.body) }.to_return(status: 202, body: { id: 3 }.to_json)
    visit conversation_path(@conversation)
    assert evaluate_script("matchMedia('(pointer: coarse)').matches"), "a phone's pointer is a finger"
    box = find("#composer textarea")
    assert_equal "enter", box[:enterkeyhint], "the keyboard's key says return, not send"

    box.send_keys("Pack the passport", :enter, :enter, "and the charger")
    assert_equal "Pack the passport\n\nand the charger", box.value
    sleep 0.3
    assert_no_selector "#messages > [data-pending]"
    assert_not_requested submit

    click_on "Send"
    assert_selector "#messages > [data-pending]", text: "and the charger"
    wait_until { sent }
    # A form sends its lines as CRLF, as every form does.
    assert sent["content"].gsub("\r\n", "\n").start_with?("Pack the passport\n\nand the charger"), "sent as typed, its lines and all"
  end

  test "the agent's page, its settings and the other screens fit the screen" do
    with_setting(:campfire, :url, "http://campfire") do
      @agent.create_campfire_bot!(bot_key: "4-abc123", rooms: { "3" => "Trips" })
      wiki = create_mcp_server(@agent, name: "wiki", tools: [ mcp_tool("search") ])
      { settings_path => ".settings-nav", settings_account_path => "h1", agent_path(@agent) => "form", agent_instructions_path(@agent) => "textarea",
        agent_tools_path(@agent) => ".ui-meter", agent_skills_path(@agent) => "h1", agent_prompts_path(@agent) => "h1",
        agent_routines_path(@agent) => "h1", agent_permissions_path(@agent) => "h1", agent_computer_path(@agent) => "#computer",
        agent_channels_path(@agent) => "#campfire", root_path => ".conversation-row", new_agent_path => "form",
        connectors_path => "h1", connector_path(wiki) => "h1", conversation_connectors_path(@conversation) => "h1",
        subscriptions_path => "h1", new_agent_skill_path(@agent) => "form", new_agent_prompt_path(@agent) => "form" }.each do |path, ready|
        visit path
        assert_selector ready
        assert_fits_width(path:)
        assert_thumb_sized ".page .button", ".settings .button", ".app-header .button", ".app-header__back", ".ui-row", ".settings-nav__link",
          ".ui-row__select", ".ui-row__input"
      end
    end
  end

  test "on a phone, Settings is one level at a time: tap in, and the header goes back up" do
    visit settings_path
    assert_selector ".settings__nav", visible: true
    assert_no_selector ".settings__pane", visible: true
    assert_selector ".app-header .settings__up", text: "Agents", visible: true
    assert_no_selector ".settings-nav__out", visible: true

    find(".settings-nav__link", text: @agent.name).click
    assert_current_path agent_path(@agent)
    assert_no_selector ".settings__nav", visible: true
    assert_selector "h1", text: @agent.name
    find(".settings__sections .ui-row", text: "Tools").click
    assert_current_path agent_tools_path(@agent)
    assert_selector ".ui-meter"

    find(".settings__up", text: @agent.name).click
    assert_current_path agent_path(@agent)
    find(".settings__up", text: "Settings").click
    assert_current_path settings_path
    assert_selector ".settings__nav", visible: true
  end

  test "an agent's General rows keep one line, label left and value right, at 390 px and at 320 px with a long time zone" do
    @agent.update!(time_zone: "International Date Line West", title: "Chief of Staff to the Household")
    [ 390, 320 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 844, deviceScaleFactor: 3, mobile: true)
      visit agent_path(@agent)
      assert_selector "#agent_general"
      rows = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("#agent_general .ui-row")].map(row => {
          const label = row.querySelector(".ui-row__label").getBoundingClientRect()
          const value = row.querySelector(".ui-row__value :is(select, input)").getBoundingClientRect()
          return { text: row.querySelector(".ui-row__label").textContent.trim(), labelTop: label.top, labelHeight: label.height, labelRight: label.right,
                   valueTop: value.top, valueLeft: value.left, valueRight: value.right, rowRight: row.getBoundingClientRect().right }
        })
      JS
      assert_equal [ "Title", "Model", "Thinking", "Time zone" ], rows.pluck("text")
      rows.each do |row|
        assert_operator (row["valueTop"] - row["labelTop"]).abs, :<, row["labelHeight"], "#{width}px: #{row["text"]}'s value is not on its label's line"
        assert_operator row["valueLeft"], :>=, row["labelRight"], "#{width}px: #{row["text"]}'s value overlaps its label"
        assert_operator row["valueRight"], :<=, row["rowRight"], "#{width}px: #{row["text"]}'s value leaves its row"
      end
      assert_fits_width
      assert_thumb_sized ".ui-row", ".ui-row__select", ".ui-row__input"
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 3, mobile: true)
  end

  test "the whole row of an agent in the list opens it" do
    visit root_path
    row = rect(".conversation-row")
    page.driver.browser.action.move_to_location(row["right"] - 120, row["top"] + row["height"] - 8).click.perform
    assert_current_path conversation_path(@conversation)
  end

  test "on the computer's screen, a bar opens the phone's keyboard and passes keys, Ctrl, Esc, Tab, Ctrl-Alt-Del and pasted text on" do
    @agent.create_computer!(provider: "sprites", state: "on")
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12/computer}).to_return(body: { waking: "warm" }.to_json)
    visit conversation_screen_path(@conversation)
    assert_selector ".screen__bar"
    assert_text "Tap Keyboard to type."
    assert_fits_width
    assert_thumb_sized ".screen__bar .button"

    # noVNC can't reach a computer here; a stand-in records what it is asked to send.
    wait_until { page.evaluate_script("!!#{SCREEN}?.rfb") }
    page.execute_script(<<~JS)
      const screen = #{SCREEN}; screen.rfb.disconnect()
      screen.rfb = { sent: [], disconnect() {}, sendCtrlAltDel() { this.sent.push("ctrl-alt-del") },
        sendKey(keysym, code, down) { this.sent.push([ keysym, down ?? null ]) }, clipboardPasteFrom(text) { this.sent.push(text) } }
    JS

    click_on "Keyboard"
    assert page.evaluate_script("document.activeElement.matches('.screen__keys')"), "Keyboard focuses the box the phone types into"
    page.driver.browser.action.send_keys("hi", :backspace).perform
    find("[data-screen-target=ctrl]").click
    click_on "Esc"
    assert page.evaluate_script("document.activeElement.matches('.screen__keys')"), "a key on the bar leaves the phone's keyboard open"
    click_on "Tab"
    click_on "Ctrl-Alt-Del"
    find(".screen__paste > summary").click
    assert_fits_width ".screen__paste-form"
    find(".screen__paste textarea").set("a b")
    click_on "Type it"

    assert_equal [ [ 0x68, nil ], [ 0x69, nil ], [ 0xff08, nil ], [ 0xffe3, true ], [ 0xff1b, nil ], [ 0xffe3, false ], [ 0xff09, nil ],
                   "ctrl-alt-del", "a b", [ 0x61, nil ], [ 0x20, nil ], [ 0x62, nil ] ], page.evaluate_script("#{SCREEN}.rfb.sent")
  end

  test "the thread's header is one bar: Agents, the agent, and a menu that Tools and New agent fold into" do
    visit conversation_path(@conversation)
    # Why it waits or stopped is the bar's foot, a line of its own; the rest is one line.
    assert_selector ".chat__header .chat__status", text: "Waiting for you"
    middles = page.evaluate_script("[...document.querySelectorAll('.chat__header > :not(.chat__status)')].filter(e => e.offsetParent).map(e => { const r = e.getBoundingClientRect(); return r.top + r.height / 2 })")
    assert_operator middles.max - middles.min, :<, 8, "the header wraps"
    assert_no_link "New agent"
    find(".chat__more").click
    # The menu slides up from the bottom, as an action sheet does; a finger reaches it once it stops.
    page.evaluate_async_script("Promise.all(document.getAnimations().map(it => it.finished)).then(arguments[0])")
    assert_operator rect("#chat_actions")["bottom"], :>, viewport_height - 40, "the menu is a sheet at the bottom"
    assert_thumb_sized "#chat_actions .button"
    click_on "Tools"
    assert_current_path agent_tools_path(@agent)
  end

  test "back slides the page off, but after a swipe the browser already animated (an iPhone's edge swipe) it just appears" do
    # Chrome has no edge swipe; the next back is marked as Safari marks one, before the app's own listener reads it.
    # The browser outlives the test, so the script leaves with it (below).
    watcher = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)["identifier"]
      window.swipeNext = false
      window.addEventListener("popstate", event => {
        if (window.swipeNext) Object.defineProperty(event, "hasUAVisualTransition", { value: true })
      }, { capture: true })
      // Each visit's view-transition animations, as seen frame by frame for most of a second: the app's slides,
      // and every one, the browser's own (-ua-…) too, which hold the page left on screen while they run.
      window.slides = []
      window.animations = []
      document.addEventListener("turbo:visit", () => {
        const seen = new Set(), start = performance.now()
        const look = () => {
          document.getAnimations().filter(it => it.effect?.pseudoElement?.startsWith("::view-transition")).forEach(it => seen.add(it.animationName))
          if (performance.now() - start < 700) return requestAnimationFrame(look)
          window.slides.push([ ...seen ].filter(it => !it.startsWith("-ua-")).sort().join(" "))
          window.animations.push([ ...seen ].sort().join(" "))
        }
        requestAnimationFrame(look)
      })
    JS
    visit settings_path
    click_on "You", match: :first
    assert_current_path settings_account_path
    page.go_back
    assert_current_path settings_path
    wait_until { page.evaluate_script("window.slides.length") >= 2 }
    assert_equal "drift-in push-out", page.evaluate_script("window.slides.at(-1)"), "a back the browser didn't animate slides"

    click_on "You", match: :first
    assert_current_path settings_account_path
    assert_no_selector "html[data-swiped]", visible: :all
    page.execute_script("window.swipeNext = true")
    page.go_back
    assert_current_path settings_path
    assert_selector "html[data-swiped]", visible: :all
    wait_until { page.evaluate_script("window.slides.length") >= 4 }
    assert_equal "", page.evaluate_script("window.slides.at(-1)"), "after the browser's own slide, no second one"
    assert_equal "", page.evaluate_script("window.animations.at(-1)"), "nor anything holding the page left on screen"

    page.execute_script("window.swipeNext = false")
    click_on "You", match: :first
    assert_current_path settings_account_path
    assert_no_selector "html[data-swiped]", visible: :all
  ensure
    page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: watcher) if watcher
  end

  # The thread is the page, not a box inside it: iOS selects text, drags its handles and scrolls on a page as
  # its own, and a box inside one fights it. The header and the composer stick to the screen's edges.
  test "on a phone the thread scrolls as the page, its header and composer stay put, and Jump to latest sits clear of Details" do
    long_thread(40)
    visit conversation_path(@conversation)
    assert_text "Message 40"
    assert_equal "visible", evaluate_script("getComputedStyle(document.querySelector('.chat__viewport')).overflowY")
    assert_operator evaluate_script("document.scrollingElement.scrollHeight"), :>, viewport_height + 1000, "the page itself is long"
    wait_until { from_end < 2 }
    header, composer = rect(".chat__header")["top"].round, rect(".composer")["bottom"].round

    execute_script("scrollBy(0, -900)")
    assert_selector ".chat__jump"
    assert_equal [ header, composer ], [ rect(".chat__header")["top"].round, rect(".composer")["bottom"].round ], "the header and the composer stayed put"
    assert_thumb_sized ".chat__jump"
    jump, details = rect(".chat__jump"), rect(".status-line__details > summary")
    assert_operator jump["bottom"], :<=, details["top"], "Jump to latest is clear of Details, above it"
    hits = evaluate_script(<<~JS)
      (() => { const r = document.querySelector(".chat__jump").getBoundingClientRect()
        return [ [ r.left + r.width / 2, r.top + r.height / 2 ], [ r.left + 2, r.top + r.height / 2 ], [ r.right - 2, r.top + r.height / 2 ],
          [ r.left + r.width / 2, r.top + 2 ], [ r.left + r.width / 2, r.bottom - 2 ] ].map(([ x, y ]) => document.elementFromPoint(x, y)?.closest(".chat__jump") ? "jump" : "other") })()
    JS
    assert_equal %w[ jump ] * 5, hits, "a tap anywhere on it reaches it"

    find(".chat__jump").click
    wait_until { from_end < 2 }
    assert_no_selector ".chat__jump"
  end

  test "on a phone Jump to latest hides while the latest message shows, so a card just above the composer keeps its buttons clear" do
    long_thread(40)
    @conversation.messages.create!(entry_key: "card", entry_id: 60, role: "assistant", content: "I'd like to forget an old note.",
      tool_calls: [ { "id" => "call_card", "name" => "forget_note" } ])
    ask("forget_note", { "key" => "old" }, "call_card")
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/12/wakes}).to_return(status: 202, body: "{}")
    visit conversation_path(@conversation)
    assert_selector ".approval", text: "Allow forget note?"
    wait_until { from_end < 2 }

    # Up a little, as a reader does, until the card's buttons sit just above the composer and the status line.
    execute_script(<<~JS)
      const card = document.querySelector(".approval").getBoundingClientRect(), foot = document.querySelector(".chat__footer").getBoundingClientRect()
      scrollBy(0, card.bottom - foot.top + 4)
    JS
    assert_operator from_end, :>, 48, "scrolled off the end"
    assert_no_selector ".chat__jump"
    hits = evaluate_script(<<~JS)
      [ ...document.querySelectorAll(".approval .ui-card__actions button") ].map(b => { const r = b.getBoundingClientRect()
        return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) === b ? b.textContent.trim() : "covered" })
    JS
    assert_equal [ "Allow once", "Always for this agent", "Deny" ], hits

    # Further up, the pill is back, and takes the reader to the end.
    execute_script("scrollBy(0, -900)")
    assert_selector ".chat__jump"
    find(".chat__jump").click
    wait_until { from_end < 2 }
    assert_no_selector ".chat__jump"

    click_on "Deny"
    assert_selector ".ui-trace", text: "Declined forget note"
  end

  test "on a phone a thread's bar is glass over the messages, as iOS's is, and covers none of them at the top" do
    long_thread(40)
    visit conversation_path(@conversation)
    assert_text "Message 40"
    bar = evaluate_script("(s => [ s.backdropFilter, s.backgroundColor ])(getComputedStyle(document.querySelector('.chat__header')))")
    assert_match "blur", bar.first
    assert_match(/\/ 0\.\d|, 0\.\d+\)/, bar.last, "the bar lets the messages show through")

    execute_script("scrollTo(0, 0)")
    wait_until { evaluate_script("scrollY").zero? }
    assert_operator rect(".chat__messages")["top"], :>=, rect(".chat__header")["bottom"], "at the top the bar covers no message"
  end

  test "on a phone scrolling up loads earlier messages above and keeps the reader's place" do
    long_thread(Conversation::Page::SIZE + 20)
    visit conversation_path(@conversation)
    assert_selector "turbo-frame.chat__earlier[src]", visible: :all
    reading = find("#message_#{@conversation.messages.find_by!(entry_key: "long20").id}")
    before = reading.evaluate_script("(scrollTo(0, 0), this.getBoundingClientRect().top)")
    assert_text "Message 20."
    assert_in_delta before, reading.evaluate_script("this.getBoundingClientRect().top"), 2
  end

  test "a reply's Copy is Share on a phone, and opens the system's share sheet with the reply's words" do
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: "navigator.share = async data => { window.shared = data }")
    visit conversation_path(@conversation)
    find(".ui-message[data-role=assistant] .ui-bubble", match: :first).click
    share = find("[data-copy-reply][data-shares]")
    assert_equal "Share this reply", share[:title]
    assert_thumb_sized "[data-copy-reply]"
    share.click
    assert_match(/\A\*\*Sure\.\*\*/, page.evaluate_script("window.shared.text"))
  end

  test "a phone's list has no bar: Settings is beside the title, and the search and New agent are at the foot, in reach" do
    visit root_path
    assert_selector ".conversation-row"
    assert_no_selector ".app-header", visible: true
    assert_thumb_sized ".page__settings", "#new_agent", ".conversation-filters__search", ".conversation-filters__select"
    [ "#new_agent", ".conversation-filters__search" ].each do |selector|
      assert_operator rect(selector)["bottom"], :<=, viewport_height, "#{selector} is below the screen"
      assert_operator rect(selector)["top"], :>=, viewport_height - 80, "#{selector} is not at the foot"
    end
    assert_operator rect(".conversation-filters__search")["right"], :<=, rect("#new_agent")["left"], "the search runs under New agent"

    click_on "Settings"
    assert_current_path settings_path
    find(".settings__up", text: "Agents").click
    click_on "New agent"
    assert_current_path new_agent_path
  end

  test "on a phone, Agents goes back to the list, as Messages does" do
    visit conversation_path(@conversation)
    assert_no_selector ".chat-panel__open", visible: true
    assert_thumb_sized ".chat__back"
    click_on "Agents"
    assert_current_path root_path
    assert_selector ".conversation-row", text: @agent.name
  end

  test "every icon-only control says what it does, to a screen reader and as a tooltip" do
    [ conversation_path(@conversation), components_path ].each do |path|
      visit path
      unnamed = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("button, a, summary, label.button")]
          .filter(e => e.getClientRects().length && !e.textContent.trim() && !e.querySelector("img[alt]:not([alt=''])"))
          .filter(e => !e.getAttribute("aria-label") || !e.title)
          .map(e => e.outerHTML.slice(0, 120))
      JS
      assert_equal [], unnamed, "on #{path}"
    end
  end

  test "on a phone the canvas is a full-screen sheet over the thread, its controls thumb-sized" do
    ask("write_document", { "title" => "Packing list", "body" => "- passport\n- #{LONG}\n\n```\na_line_of_code_much_too_long_for_a_phone = call(argument_one, argument_two)\n```\n" }, "call_doc")
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [
      { id: "1", entryId: 1, role: "assistant", content: "[tool: write_document]", toolCalls: [ { id: "call_doc", name: "write_document" } ] }
    ], cursor: 1, more: false }.to_json)
    visit conversation_path(@conversation)
    assert_thumb_sized ".document-card .button"
    find(".document-card").click_on "Open"

    assert_selector ".canvas__title", text: "Packing list"
    sheet = rect(".canvas-frame")
    assert_equal [ 0, 0, 390, viewport_height ], sheet.values_at("left", "top", "width", "height").map(&:round)
    assert_fits_width
    assert_thumb_sized ".canvas__mode", ".canvas__done", ".canvas__bar .button"
    choose "Edit", allow_label_click: true
    assert_thumb_sized ".canvas__form .button", ".canvas__text"
    assert_fits_width

    click_on "Done"
    assert_no_selector ".canvas"
    assert_selector "#composer textarea"
  end

  test "signing in fits the screen" do
    Capybara.reset_sessions!
    visit sign_in_path
    assert_selector ".sign-in .button"
    assert_fits_width
    assert_thumb_sized ".sign-in .button"
  end

  private
    SCREEN = "Stimulus.getControllerForElementAndIdentifier(document.querySelector('.screen'), 'screen')"

    def ask(tool, arguments, call_id)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: 7, call_id: call_id, tool: tool, arguments: payload[:arguments], digest: payload[:digest])
    end

    def viewport_height = page.evaluate_script("window.innerHeight")
    def from_end = page.evaluate_script("document.scrollingElement.scrollHeight - scrollY - innerHeight")

    def long_thread(count)
      count.times do |n|
        @conversation.messages.create!(entry_key: "long#{n}", entry_id: n + 10, role: n.even? ? "user" : "assistant",
          content: "Message #{n + 1}. A few words, so a phone wraps them onto more than one line of the thread.")
      end
    end
    def rect(selector) = page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().toJSON()")

    # Nothing reaches past the screen's edge, except inside something that scrolls on its own (code, a table).
    def assert_fits_width(selector = "body *", path: current_path)
      wide = page.evaluate_script(<<~JS)
        [...document.querySelectorAll(#{selector.to_json})].filter(e => { const r = e.getBoundingClientRect();
          return r.width && (r.right > innerWidth + 1 || r.left < -1) && !e.closest("details:not([open]) > :not(summary)") && !e.parentElement?.closest("pre, table") })
          .slice(0, 5).map(e => e.outerHTML.slice(0, 120))
      JS
      assert_empty wide, "#{path}: wider than the screen"
      assert_equal page.evaluate_script("innerWidth"), page.evaluate_script("document.documentElement.scrollWidth"), "#{path} scrolls sideways"
    end

    def assert_thumb_sized(*selectors)
      small = page.evaluate_script(<<~JS)
        [...document.querySelectorAll(#{selectors.join(", ").to_json})].filter(e => { const r = e.getBoundingClientRect(); return r.width && r.height < 43.5 })
          .map(e => `${e.outerHTML.slice(0, 80)} ${Math.round(e.getBoundingClientRect().height)}px`)
      JS
      assert_empty small, "#{current_path}: too small for a thumb"
    end
end
