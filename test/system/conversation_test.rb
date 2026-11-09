require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# A real browser against Falcon. The sidecar is stubbed at Rails' HTTP client
# (WebMock, in this process); the sidecar's own suite runs the real runtime.
class ConversationTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    payload = invocation_payload(@conversation, tool: "ask_person", arguments: { "question" => "Tea or coffee?", "options" => %w[ Tea Coffee ] }, call_id: "call_1")
    Invocation.receive(@conversation, task_id: 7, call_id: "call_1", tool: "ask_person", arguments: payload[:arguments], digest: payload[:digest])
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "waiting", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [
        { id: "1", entryId: 1, role: "user", content: "Help me choose a drink" },
        { id: "2", entryId: 2, role: "assistant", content: "**Happy to.**[tool: ask_person]", toolCalls: [ { id: "call_1", name: "ask_person" } ] }
      ], cursor: 2, more: false }.to_json)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "the person reads the conversation, answers the agent's question, and sends a message" do
    visit conversation_path(@conversation)

    assert_selector ".ui-bubble", text: "Help me choose a drink"
    assert_selector ".ui-markdown strong", text: "Happy to."
    assert_selector ".question .ui-card__title", text: "Tea or coffee?"

    find(".question__option", text: "Coffee").click
    click_on "Answer"
    assert_selector ".ui-trace[data-status=running]", text: "Running ask person…"
    assert_equal [ "Coffee" ], @conversation.invocations.sole.answer.selections

    submit = stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 3 }.to_json)
    # Answered, the agent works again, though the sidecar still holds the wait:
    # the composer's stop square says so, and the header says nothing.
    assert_selector ".chat__status[data-status=running]", text: ""
    assert_selector ".composer__stop"
    find("#composer textarea").fill_in(with: "Thanks!")
    click_on "Queue"
    # Shown at once, last, until its committed copy arrives.
    assert_selector "#messages > [data-pending]:last-child", text: "Thanks!"
    assert_selector "#composer textarea" do |box| box.value.empty? end
    wait_until { WebMock::RequestRegistry.instance.times_executed(submit.request_pattern).positive? }
    assert_requested submit
  end

  # The page is the window: a flash takes its line, the composer stays on
  # screen, and only the sidebar and the messages scroll.
  test "with a flash showing, a conversation's page fits the window and does not scroll" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    visit conversation_path(@conversation)
    assert_selector ".ui-bubble", text: "Help me choose a drink"
    find("#composer textarea").fill_in(with: "/model gemini")
    find("#composer textarea").send_keys(:enter)
    assert_selector ".flash[data-kind=alert]", text: "No model matches “gemini”."

    assert page.evaluate_script("document.scrollingElement.scrollHeight <= window.innerHeight"), "the document scrolls"
    flash, composer = %w[ .flash #composer ].map { page.evaluate_script("document.querySelector('#{it}').getBoundingClientRect().toJSON()") }
    assert_operator flash["top"], :>=, page.evaluate_script("document.querySelector('.app-header').getBoundingClientRect().bottom"), "the flash is under the header, not behind it"
    assert_operator composer["bottom"], :<=, page.evaluate_script("window.innerHeight"), "the composer is on screen"
  end

  test "a suggestion in an empty conversation is shown sent at once, with the agent working under it" do
    empty = create_conversation(@agent, durable_id: "13")
    stub_request(:get, "#{SIDECAR}/v1/conversations/13").with(query: hash_including({}))
      .to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/13/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/13/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    visit conversation_path(empty)

    click_on "What can you do?"

    assert_no_selector ".chat__empty"
    assert_selector "#messages > [data-pending]", text: "What can you do?"
    assert_selector ".chat__live .ui-typing", text: "Working…", visible: :all
  end

  test "a running command's output shows as it prints, an older frame never overwrites a newer one, and a script's calls keep their order" do
    busy = create_conversation(@agent, durable_id: "15")
    script = { id: "toolu_s", name: "codemode", arguments: { code: "await tools.bash({ command: 'make' })" } }
    stub_request(:get, "#{SIDECAR}/v1/conversations/15").with(query: hash_including({}))
      .to_return(body: { status: "running", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/15/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "assistant", content: "", toolCalls: [ script, { id: "call_b", name: "bash", arguments: { command: "ls" } } ] } ],
        cursor: 1, more: false }.to_json)
    visit conversation_path(busy)
    assert_selector ".ui-trace", text: "Running bash…"

    frame = ->(seq, tools) { busy.receive_frame(seq: seq, busy: true, tail: "", failure: nil, tools: tools) }
    nested = ->(id, output) { { "callId" => "toolu_s/#{id}", "name" => "bash", "status" => "running", "output" => output } }
    frame.(10, [ { "callId" => "call_b", "name" => "bash", "status" => "running", "output" => "first\n" }, nested.("c1", "a"), nested.("c2", "b") ])
    assert_selector "##{Invocation.dom_target('call_b')}_output", text: "first"
    frame.(12, [ nested.("c1", "a and more") ])
    assert_selector ".tool-call__calls .tool-call__output", text: "a and more"
    frame.(11, [ { "callId" => "call_b", "name" => "bash", "status" => "running", "output" => "stale" }, nested.("c1", "stale") ])
    frame.(13, [ { "callId" => "call_b", "name" => "bash", "status" => "running", "output" => "first\nsecond" } ])
    assert_selector "##{Invocation.dom_target('call_b')}_output", text: "second"
    assert_no_text "stale"
    lines = all("##{Invocation.dom_target('toolu_s')}_calls > .tool-call").map { it[:id] }
    assert_equal [ Invocation.dom_target("toolu_s/c1"), Invocation.dom_target("toolu_s/c2") ], lines
  end

  test "a streaming reply shows whole from frames that carry only what changed, and an older frame never overwrites a newer one" do
    busy = create_conversation(@agent, durable_id: "16")
    stub_request(:get, "#{SIDECAR}/v1/conversations/16").with(query: hash_including({}))
      .to_return(body: { status: "running", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/16/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "user", content: "Plan Lisbon" } ], cursor: 1, more: false }.to_json)
    visit conversation_path(busy)
    frame = ->(seq, tail, sent = nil) { busy.receive_frame(seq: seq, busy: true, tail: tail, thinking: "Hmm", failure: nil, sent: sent && { reply: sent.bytesize, thinking: 3 }) }

    first = "Here's the plan:\n\nFli"
    frame.(10, first)
    assert_selector ".chat__live .ui-bubble", text: "Fli"
    second = "#{first}ghts on the 12th.\n\nShall I"
    frame.(11, second, first)
    third = "#{second} book them?"
    frame.(13, third, second)
    assert_selector ".chat__live .ui-bubble", text: "Shall I book them?"
    frame.(12, "#{second} bo", second) # late
    sleep 0.3
    blocks = all(".chat__live .ui-bubble .ui-markdown .ui-markdown").map(&:text)
    assert_equal [ "Here's the plan:", "Flights on the 12th.", "Shall I book them?" ], blocks
    assert_selector ".chat__live .ui-reasoning", text: "Thought process", visible: :all
  end

  test "on a narrow screen a long title and the working controls stay on the page, and the box shrinks once sent" do
    busy = create_conversation(@agent, durable_id: "14")
    name_agent(busy.agent, "What time is it for me right now? After checking, write three short paragraphs")
    stub_request(:get, "#{SIDECAR}/v1/conversations/14").with(query: hash_including({}))
      .to_return(body: { status: "running", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/14/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "user", content: "Hello" } ], cursor: 1, more: false }.to_json)
    steer = stub_request(:post, "#{SIDECAR}/v1/conversations/14/submissions").with(body: hash_including("whenBusy" => "steer"))
      .to_return(status: 202, body: { id: 2 }.to_json)
    queue = stub_request(:post, "#{SIDECAR}/v1/conversations/14/submissions").with(body: hash_including("whenBusy" => "followUp"))
      .to_return(status: 202, body: { id: 3 }.to_json)
    page.current_window.resize_to(700, 900)
    visit conversation_path(busy)

    # While it works the header says nothing (a phone's hides the empty line): the composer's Stop says it.
    assert_selector ".chat__status[data-status=running]", text: "", visible: :all
    assert_selector ".composer__stop[aria-label=Stop]"
    assert_no_selector "#stop", visible: :all
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth"), :<=, 0

    box = find("#composer textarea")
    one_line = box.evaluate_script("this.offsetHeight")
    box.send_keys("First line", [ :shift, :enter ], "second line", [ :shift, :enter ], "third line")
    # The box grows on input, a frame after the keys: wait for it rather than read it once.
    wait_until { box.evaluate_script("this.offsetHeight") > one_line }
    sent_with = find("#composer input[name=request_id]", visible: false).value
    box.send_keys(:enter)
    assert_selector "#messages > [data-pending]", text: "third line"
    assert_equal one_line, box.evaluate_script("this.offsetHeight")
    # Typing on at once: the server renews only the request id, so nothing typed is lost.
    box.send_keys("And then")
    assert_no_selector "#composer input[name=request_id][value='#{sent_with}']", visible: false
    assert_equal "And then", box.value
    # While the agent works, Enter steered it; Queue waits for it to finish.
    assert_requested steer
    assert_button "Steer"
    box.send_keys(" this")
    click_on "Queue"
    assert_selector "#messages > [data-pending]", text: "And then this"
    assert_requested queue
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  # Everything the header can hold at once: a long title, a run that stopped
  # with a long reason, a connector that needs the person, and the screen.
  test "a long title, a stopped run's reason and every header button stay apart and on the page, at 1280 and 390 pixels" do
    @agent.user.mcp_servers.create!(name: "notes", url: "https://notes.example.com/mcp", sign_in_needed: true)
    stopped = create_conversation(@agent, durable_id: "15")
    stopped.agent.create_computer!(provider: "sprites", state: "on")
    name_agent(stopped.agent, "What time is it for me right now? After checking, write three short paragraphs about it, then a poem")
    stub_request(:get, "#{SIDECAR}/v1/conversations/15").with(query: hash_including({}))
      .to_return(body: { status: "error", failure: { reason: "rate_limited" }, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/15/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "user", content: "Hello" } ], cursor: 1, more: false }.to_json)
    header = <<~JS
      const parts = { title: ".chat__title", status: ".chat__status", connectors: "#connectors_button", screen: "a[href$='/screen']", new: ".chat__new" };
      const boxes = Object.entries(parts).map(([name, selector]) => [name, document.querySelector(selector)])
        .filter(([, element]) => element && element.getClientRects().length > 0)
        .map(([name, element]) => { const r = element.getBoundingClientRect(); return { name, left: r.left, top: r.top, right: r.right, bottom: r.bottom, clipped: element.scrollWidth > element.clientWidth + 1 }; });
      const apart = (a, b) => a.right <= b.left + 0.5 || b.right <= a.left + 0.5 || a.bottom <= b.top + 0.5 || b.bottom <= a.top + 0.5;
      const overlapping = [];
      boxes.forEach((a, i) => boxes.slice(i + 1).forEach(b => { if (!apart(a, b)) overlapping.push(`${a.name}/${b.name}`); }));
      return { overlapping, names: boxes.map(box => box.name), title: boxes.find(box => box.name === "title"),
               pastTheEdge: boxes.filter(box => box.left < 0 || box.right > window.innerWidth).map(box => box.name),
               statusClipped: boxes.find(box => box.name === "status")?.clipped,
               overflow: document.documentElement.scrollWidth - window.innerWidth };
    JS

    [ [ 1280, 800 ], [ 390, 844 ] ].each do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: false)
      visit conversation_path(stopped)
      assert_selector ".chat__status", text: "Stopped: the model's usage limit is reached"
      # A phone folds the buttons into a menu.
      assert_selector ".chat__more"
      measured = page.evaluate_script("(() => { #{header} })()")

      assert_equal [], measured["overlapping"], "overlap at #{width}"
      assert_equal [], measured["pastTheEdge"], "past the edge at #{width}"
      assert_operator measured["overflow"], :<=, 0, "sideways scroll at #{width}"
      assert_not measured["statusClipped"], "status cut off at #{width}"
      assert_operator measured["title"]["right"] - measured["title"]["left"], :>=, 80, "title squeezed at #{width}"
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "the person attaches a picture, sees it before and after sending, and the agent gets it" do
    png = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
    file = Rails.root.join("tmp/system-test-dot-#{SecureRandom.hex(4)}.png").tap { it.binwrite(png) }
    sent = nil
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").with { sent = JSON.parse(it.body) }.to_return(status: 202, body: { id: 3 }.to_json)
    visit conversation_path(@conversation)

    find("#composer input[type=file]", visible: false).attach_file(file.to_s)
    assert_selector ".composer__thumb a[target=_blank] img", count: 1
    click_on "Remove #{file.basename}"
    assert_no_selector ".composer__thumb"
    find("#composer input[type=file]", visible: false).attach_file(file.to_s)
    find("#composer textarea").send_keys("What is this?", :enter)

    # Shown at once, picture and words, and the box empties.
    assert_selector "#messages > [data-pending] a.ui-images__link[target=_blank] img[src^='blob:']"
    assert_selector "#messages > [data-pending]", text: "What is this?"
    assert_no_selector ".composer__thumb"
    assert_equal [ { "type" => "text", "text" => "What is this?" }, { "type" => "image", "data" => Base64.strict_encode64(png), "mimeType" => "image/png" } ],
      sent["content"]
  ensure
    file&.delete
  end

  test "New agent from here on a reply opens the form, and starting it lands in the new agent's thread, which begins with the copy" do
    drinks = create_conversation(@agent, durable_id: "16")
    name_agent(drinks.agent, "Drinks")
    history = [ { id: "1", entryId: 1, role: "user", content: "Tea please" }, { id: "2", entryId: 2, role: "assistant", content: "Tea it is." } ]
    { "16" => history + [ { id: "3", entryId: 3, role: "user", content: "Make it green" } ], "50" => history }.each do |id, entries|
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{id}").with(query: hash_including({})).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{id}/entries").with(query: hash_including({}))
        .to_return(body: { entries: entries, cursor: entries.last[:entryId], more: false }.to_json)
    end
    asked = nil
    fork = stub_request(:post, "#{SIDECAR}/v1/conversations/16/forks").with(body: hash_including(at: 2)) { asked = JSON.parse(it.body) }
      .to_return(status: 201, body: { id: 50 }.to_json)
    visit conversation_path(drinks)

    # A tap on the bubble shows its actions on a touch screen, as the test's browser is.
    reply = find("#messages > [data-role=assistant]", text: "Tea it is.")
    reply.find(".ui-bubble").click
    reply.click_on "New agent from here"

    assert_selector "h1", text: "New agent"
    assert_selector "#agent_from", text: "Starts with a copy of Drinks's thread"
    fill_in "Name", with: "Tea taster"
    click_on "Start"

    assert_selector ".chat__title", text: "Tea taster"
    assert_selector "#messages .ui-bubble", text: "Tea please"
    assert_no_selector "#messages .ui-bubble", text: "Make it green"
    taster = @agent.user.agents.find_by!(name: "Tea taster")
    assert_current_path conversation_path(taster.conversation)
    assert_requested fork
    assert_equal taster.id.to_s, asked.dig("into", "workspaceId")
    assert_equal "50", taster.conversation.durable_id
  end

  test "a conversation with a Sprite has an Open screen link to its screen page; without one, none" do
    visit conversation_path(@conversation)
    assert_selector ".ui-bubble", text: "Help me choose a drink"
    assert_no_link "Open screen"

    @agent.create_computer!(provider: "sprites", state: "on")
    visit conversation_path(@conversation)
    find(".chat__more").click
    assert_link "Open screen", href: conversation_screen_path(@conversation)
  end
end
