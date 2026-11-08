require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# The canvas: a document the agent wrote, opened from its card beside the
# thread, edited in one box, looked back through and exported, and the
# person's edits reaching the agent with their next message.
class CanvasTest < ApplicationSystemTestCase
  include AgentTestHelper

  BODY = "# Lisbon\n\n- Day 1: *Alfama*\n- Day 2: Belém\n\n```ruby\nputs \"`tick`\"\n```\n".freeze

  setup do
    install_sidecar_settings
    mock_ajent_auth(name: "Maya")
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    write("Trip plan", BODY)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(body: { entries: [
      { id: "1", entryId: 1, role: "user", content: "Plan three days in Lisbon" },
      { id: "2", entryId: 2, role: "assistant", content: "[tool: write_document]", toolCalls: [ { id: "call_doc", name: "write_document" } ] },
      { id: "3", entryId: 3, role: "assistant", content: "It's in the canvas." }
    ], cursor: 3, more: false }.to_json)
    @document = @agent.documents.sole
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "the agent's card opens the canvas beside the thread, rendered, and Done closes it" do
    visit conversation_path(@conversation)
    within(".document-card") do
      assert_text "Trip plan"
      assert_text "Wrote · Markdown"
      click_on "Open"
    end

    assert_selector ".canvas .canvas__title", text: "Trip plan"
    assert_selector ".canvas__page h1", text: "Lisbon"
    assert_selector ".canvas__page em", text: "Alfama"
    assert_selector ".canvas__page pre code", text: "puts"
    assert_no_selector "[data-pane=edit] textarea", visible: true
    chat, canvas = rect(".chat"), rect(".canvas-frame")
    assert_operator canvas["left"], :>=, chat["right"] - 1, "the canvas sits beside the thread"
    assert_operator chat["width"], :>=, 320, "the thread stays readable"
    assert_selector ".chat .ui-bubble", text: "It's in the canvas."
    assert_equal "Trip plan", page.evaluate_script("document.activeElement.textContent"), "focus moves to the canvas"

    click_on "Done"
    assert_no_selector ".canvas"
    assert_selector ".chat .ui-bubble", text: "It's in the canvas."
  end

  test "the person edits and saves, looks back through the history and restores the first version" do
    visit conversation_path(@conversation)
    find(".document-card").click_on "Open"
    choose "Edit", allow_label_click: true
    box = find("[data-pane=edit] textarea")
    assert_equal BODY, box.value
    box.fill_in(with: "# Lisbon\n\n- Day 1: Sintra\n")
    click_on "Save"

    assert_selector ".canvas__page li", text: "Day 1: Sintra"
    assert_selector ".canvas__version", text: /Version 2 · you/
    assert_equal [ 2, "person" ], @document.reload.current_version.then { [ it.number, it.author ] }

    choose "History", allow_label_click: true
    within ".canvas__history" do
      assert_selector "li", count: 2
      assert_selector "li:first-child", text: /Version 2\s*You/
      assert_selector "li:last-child", text: /Version 1\s*#{@agent.name}/
      find("li:last-child").click_on "Restore"
    end

    assert_selector ".canvas__version", text: /Version 3 · you/
    assert_selector ".canvas__page em", text: "Alfama"
    assert_equal BODY, @document.reload.body
  end

  test "leaving the box with changes unsaved asks first" do
    visit conversation_path(@conversation)
    find(".document-card").click_on "Open"
    choose "Edit", allow_label_click: true
    find("[data-pane=edit] textarea").send_keys(" and more")

    click_on "Done"
    within("#confirm") { click_on "Cancel" }
    assert_selector ".canvas"
    click_on "Done"
    within("#confirm") { click_on "Leave" }
    assert_no_selector ".canvas"
    assert_equal BODY, @document.reload.body
  end

  test "Copy gives the source exactly, and Download its file" do
    page.driver.browser.execute_cdp("Browser.grantPermissions", origin: page.server_url, permissions: %w[ clipboardReadWrite clipboardSanitizedWrite ])
    visit conversation_path(@conversation)
    find(".document-card").click_on "Open"

    within(".canvas__bar") { click_on "Copy" }
    assert_selector ".canvas__bar", text: "Copied"
    assert_equal BODY, page.evaluate_async_script("navigator.clipboard.readText().then(arguments[0])")
    assert_selector ".canvas__bar a[download='trip-plan.md'][href='#{conversation_document_download_path(@conversation, @document)}']", text: "Download"
  end

  test "a version the agent writes shows in the open canvas as it lands" do
    visit conversation_path(@conversation)
    find(".document-card").click_on "Open"
    assert_selector ".canvas__page h1", text: "Lisbon"

    @document.edit([ { "find" => "# Lisbon", "replace" => "# Porto" } ], by: "agent")

    assert_selector ".canvas__page h1", text: "Porto"
    assert_selector ".canvas__version", text: /Version 2 · Assistant/
  end

  test "the person's edits reach the agent with their next message, as a diff, once" do
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").with { sent << JSON.parse(it.body)["content"] }.to_return(status: 202, body: { id: 4 }.to_json)
    visit conversation_path(@conversation)
    find(".document-card").click_on "Open"
    choose "Edit", allow_label_click: true
    find("[data-pane=edit] textarea").fill_in(with: BODY.sub("Belém", "Cascais"))
    click_on "Save"
    assert_selector ".canvas__page li", text: "Cascais"

    find("#composer textarea").fill_in(with: "I swapped day two.")
    find("#composer textarea").send_keys(:enter)
    wait_until { sent.any? }

    assert sent.sole.start_with?("I swapped day two.\n\n<document_changes>")
    assert_includes sent.sole, "-- Day 2: Belém\n+- Day 2: Cascais"
    assert_not @document.reload.changed_since_seen?
  end

  test "a web page shows as its highlighted source in a monospaced box, and nothing in it runs" do
    write("Landing page", %(<h1 id="hi">Hi</h1>\n<script>document.title = "ran"</script>\n), kind: "code", language: "html", call_id: "call_page")
    # Its own page: what a phone reloading the canvas, or a browser without JavaScript, shows.
    visit conversation_document_path(@conversation, @agent.documents.find_by!(title: "Landing page"))

    assert_selector ".canvas__kind", text: "HTML code"
    assert_selector ".canvas__page pre code", text: %(<script>document.title = "ran"</script>)
    assert_no_selector ".canvas__page #hi"
    assert_no_selector "iframe"
    assert_not_equal "ran", page.title
    choose "Edit", allow_label_click: true
    assert_match(/mono/i, page.evaluate_script("getComputedStyle(document.querySelector('.canvas__text')).fontFamily"))

    click_on "Done"
    assert_current_path conversation_path(@conversation)
  end

  private
    def write(title, body, kind: "markdown", language: nil, call_id: "call_doc")
      arguments = { "title" => title, "body" => body, "kind" => kind, "language" => language }.compact
      payload = invocation_payload(@conversation, tool: "write_document", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: 7, call_id: call_id, tool: "write_document", arguments: arguments, digest: payload[:digest])
    end

    def rect(selector) = page.evaluate_script("document.querySelector('#{selector}').getBoundingClientRect().toJSON()")
end
