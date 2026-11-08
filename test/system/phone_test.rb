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
    assert_thumb_sized ".question__option", ".ui-card__actions .button", ".composer__send", ".composer__attach", ".app-header__back"

    composer = rect("#composer")
    assert_operator composer["bottom"], :<=, viewport_height, "the composer is below the screen"
    assert_operator rect("#composer textarea")["width"], :>=, 180, "the message box is squeezed"

    find(".chat__rename > summary").click
    assert_selector ".chat__rename-form"
    assert_fits_width ".chat__rename-form"
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
    assert_no_link "‹ Agents", class: "settings__out"

    find(".settings-nav__link", text: @agent.name).click
    assert_current_path agent_path(@agent)
    assert_no_selector ".settings__nav", visible: true
    assert_selector "h1", text: @agent.name
    find(".settings__sections .ui-row", text: "Tools").click
    assert_current_path agent_tools_path(@agent)
    assert_selector ".ui-meter"

    find(".settings__up", text: "‹ #{@agent.name}").click
    assert_current_path agent_path(@agent)
    find(".settings__up", text: "‹ Settings").click
    assert_current_path settings_path
    assert_selector ".settings__nav", visible: true
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

  test "the thread's header keeps one line: Connectors and New agent fold into a menu" do
    visit conversation_path(@conversation)
    assert_equal 1, page.evaluate_script("new Set([...document.querySelectorAll('.chat__header > *')].filter(e => e.offsetParent).map(e => Math.round(e.getBoundingClientRect().top))).size"),
      "the header wraps"
    assert_no_link "New agent"
    find(".chat__more").click
    assert_thumb_sized "#chat_actions .button"
    click_on "Connectors"
    assert_current_path agent_tools_path(@agent)
  end

  test "Agents opens the agents list as a side panel over the thread; Escape and the backdrop close it" do
    other = create_conversation(@agent.user.agents.create!(name: "Researcher", instructions: "Research.", model: @agent.model), durable_id: "13")
    visit conversation_path(@conversation)
    assert_no_selector ".chat-sidebar", visible: true
    click_on "Agents"
    within("dialog#agents_panel[open]") do
      assert_selector ".conversation-row__link[aria-current=page] .ui-avatar"
      assert_thumb_sized ".chat-sidebar__new"
    end
    find("dialog#agents_panel").send_keys(:escape)
    assert_no_selector "dialog#agents_panel[open]"

    click_on "Agents"
    page.driver.browser.action.move_to_location(380, 400).click.perform # the backdrop, right of the panel
    assert_no_selector "dialog#agents_panel[open]"

    click_on "Agents"
    within("dialog#agents_panel") { click_on "Researcher" }
    assert_current_path conversation_path(other)
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
