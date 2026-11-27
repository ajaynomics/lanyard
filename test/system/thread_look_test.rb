require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# What makes the thread read as Messages and the app feel like a Mac's
# (docs/design.md): clean copying, a bubble's actions on a tap, the keys.
class ThreadLookTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent, durable_id: "20")
    stub_request(:get, "#{SIDECAR}/v1/conversations/20").with(query: hash_including({}))
      .to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/20/entries").with(query: hash_including({}))
      .to_return(body: { entries: [
        { id: "1", entryId: 1, role: "user", content: "Help me choose a drink" },
        { id: "2", entryId: 2, role: "assistant", content: "**Tea**, I think.\n\n```ruby\nbrew(:tea)\n```" }
      ], cursor: 2, more: false }.to_json)
    @conversation.sync!
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "copying across bubbles gives the words alone: no buttons, times or bubble colours" do
    visit conversation_path(@conversation)
    assert_selector ".ui-bubble", text: "Tea"

    text, html = page.evaluate_script(<<~JS)
      (() => {
        const range = document.createRange()
        range.selectNodeContents(document.getElementById("messages"))
        getSelection().removeAllRanges()
        getSelection().addRange(range)
        const copy = new ClipboardEvent("copy", { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
        document.querySelector("#messages .ui-bubble").dispatchEvent(copy)
        return [ copy.clipboardData.getData("text/plain"), copy.clipboardData.getData("text/html") ]
      })()
    JS

    assert_match(/\AHelp me choose a drink\n+Tea, I think\.\n+brew\(:tea\)\z/, text)
    assert_match "<strong>Tea</strong>", html
    assert_no_match(/Copy|New agent|Today|Just now|November|style=|class=/, text + html)
  end

  test "wide Markdown tables scroll without breaking short cells or widening the page" do
    body = <<~MARKDOWN
      | Item | Description | State |
      | ---- | ----------- | ----- |
      | Tile | `#{'long_value_' * 18}` | Draft |
    MARKDOWN
    stub_request(:get, "#{SIDECAR}/v1/conversations/20/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "assistant", content: body } ], cursor: 1, more: false }.to_json)
    @conversation.resync!
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
    visit conversation_path(@conversation)

    table = find(".ui-markdown table")
    assert_selector "thead th", text: "Item"
    assert_selector "tbody td", text: "Draft"
    short_cell_lines, display, scrolled, page_overflow = page.evaluate_script(<<~JS, table)
      (table => {
        const lines = [...table.querySelectorAll("th, td")].filter(cell => ["Item", "State", "Tile", "Draft"].includes(cell.textContent)).map(cell => {
          const range = document.createRange()
          range.selectNodeContents(cell)
          return range.getClientRects().length
        })
        const scroller = table.parentElement
        scroller.scrollLeft = scroller.scrollWidth
        return [lines, getComputedStyle(table).display, scroller.scrollLeft, document.documentElement.scrollWidth - innerWidth]
      })(arguments[0])
    JS

    assert_equal [ 1, 1, 1, 1 ], short_cell_lines
    assert_equal "table", display
    assert_operator scrolled, :>, 0
    assert_equal 0, page_overflow
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "the Send arrow stays centred in its circle when the draft wraps" do
    visit conversation_path(@conversation)
    input = find("#composer textarea")
    offsets = {}

    { 390 => 2, 1280 => 5 }.each do |width, repetitions|
      page.current_window.resize_to(width, 844)
      assert_equal width, page.evaluate_script("innerWidth")

      one_line_height = nil
      [ "Test message", ("Please check the draft. " * repetitions).strip ].each_with_index do |draft, index|
        input.set(draft)
        assert_selector ".composer__send .composer__idle svg"
        height, line_height, dx, dy = page.evaluate_script(<<~JS)
          (() => {
            const input = document.querySelector(".composer__input")
            const button = document.querySelector(".composer__send")
            const icon = button.querySelector(".composer__idle svg")
            const circle = button.getBoundingClientRect()
            const { x, y, width, height } = icon.getBBox()
            const arrow = new DOMPoint(x + width / 2, y + height / 2).matrixTransform(icon.getScreenCTM())
            return [input.getBoundingClientRect().height, parseFloat(getComputedStyle(input).lineHeight),
              arrow.x - (circle.left + circle.width / 2), arrow.y - (circle.top + circle.height / 2)]
          })()
        JS
        one_line_height ||= height
        assert_in_delta index * line_height, height - one_line_height, 1, "#{width}px draft should have #{index + 1} visible lines"
        offsets["#{width}px, #{index + 1} lines"] = [ dx, dy ] if dx.abs > 0.5 || dy.abs > 0.5
      end
    end

    assert_empty offsets, "Arrow centre offsets from the circle (CSS pixels): #{offsets.inspect}"
  end

  test "a tap on a reply shows its actions, and a tap elsewhere hides them; a sent message has none to edit it" do
    visit conversation_path(@conversation)
    mine = find("#messages > [data-role=user]")
    reply = find("#messages > [data-role=assistant]")
    assert_no_link "New agent from here"

    reply.find(".ui-bubble").click
    assert_link "New agent from here", href: new_agent_path(from: @conversation.messages.find_by!(entry_id: 2).id)
    mine.find(".ui-bubble").click
    assert_no_link "New agent from here"
    assert_no_button "Edit"
    assert_no_selector "#messages [data-role=user] .message__actions"
  end

  test "finder keys leave browser Find and tab numbers alone" do
    visit conversation_path(@conversation)

    find("#composer textarea").send_keys([ :control, "/" ])
    assert_selector "dialog#help_dialog[open]", text: "Search agents"
    find("dialog#help_dialog").send_keys(:escape)

    composer = find("#composer textarea")
    composer.send_keys([ :control, "f" ], [ :control, "1" ])
    assert_equal "TEXTAREA", page.evaluate_script("document.activeElement.tagName")
    assert_current_path conversation_path(@conversation)

    composer.send_keys([ :control, "k" ])
    assert_equal "sidebar_search", page.evaluate_script("document.activeElement.id")
    assert_selector '#sidebar_search[aria-keyshortcuts="Control+K Meta+K /"]'

    find(".chat__title").click
    page.driver.browser.action.send_keys("/").perform
    assert_equal "sidebar_search", page.evaluate_script("document.activeElement.id")
  end
end
