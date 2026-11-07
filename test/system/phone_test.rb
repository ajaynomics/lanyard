require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# Maya and Ajay use the app from their phones: every screen fits 390 px
# without sideways scrolling, and what a thumb presses is about 44 px.
class PhoneTest < ApplicationSystemTestCase
  include AgentTestHelper
  include EmailTestHelper

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

  test "while the agent works, Steer and Queue still leave room to type" do
    @conversation.update!(status: "running")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(body: { status: "running", failure: nil, pendingInputs: [] }.to_json)
    visit conversation_path(@conversation)
    assert_selector ".composer__steer", visible: true
    assert_fits_width
    assert_operator rect("#composer textarea")["width"], :>=, 130, "the message box is squeezed" # it grows taller as words wrap
    assert_thumb_sized ".composer__steer", ".composer__send"
  end

  test "the agent's page, its settings and the other screens fit the screen" do
    with_setting(:campfire, :url, "http://campfire") do
      @agent.create_campfire_bot!(bot_key: "4-abc123", rooms: { "3" => "Trips" })
      { agent_path(@agent) => "#campfire", edit_agent_path(@agent) => "form", root_path => ".conversation-row",
        new_agent_path => "form", connectors_path => "h1", conversation_connectors_path(@conversation) => "h1",
        subscriptions_path => "h1", new_agent_skill_path(@agent) => "form", new_agent_prompt_path(@agent) => "form" }.each do |path, ready|
        visit path
        assert_selector ready
        assert_fits_width(path:)
        assert_thumb_sized ".page .button", ".app-header .button"
      end
    end
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
