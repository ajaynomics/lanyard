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
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@bot)
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

  test "the person reads the conversation, answers the bot's question, and sends a message" do
    visit conversation_path(@conversation)

    assert_selector ".ui-bubble", text: "Help me choose a drink"
    assert_selector ".ui-markdown strong", text: "Happy to."
    assert_selector ".question .ui-card__title", text: "Tea or coffee?"

    find(".question__option", text: "Coffee").click
    click_on "Answer"
    assert_selector ".ui-trace[data-status=running]", text: "Running ask person…"
    assert_equal [ "Coffee" ], @conversation.invocations.sole.answer.selections

    submit = stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 3 }.to_json)
    assert_no_button "Steer"
    find("#composer textarea").send_keys("Thanks!", :enter)
    # Shown at once, last, until its committed copy arrives.
    assert_selector "#messages > [data-pending]:last-child", text: "Thanks!"
    assert_selector "#composer textarea" do |box| box.value.empty? end
    assert_requested submit
    assert_equal "Thanks!", @conversation.reload.title
  end

  test "a suggestion in an empty conversation is shown sent at once, with the bot working under it" do
    empty = create_conversation(@bot, durable_id: "13")
    stub_request(:get, "#{SIDECAR}/v1/conversations/13").with(query: hash_including({}))
      .to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/13/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/13/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    visit conversation_path(empty)

    click_on "What can you do?"

    assert_no_selector ".chat__empty"
    assert_selector "#messages > [data-pending]", text: "What can you do?"
    assert_selector ".chat__live .ui-shimmer", text: "Working…"
    assert_selector "#nav_title_conversation_#{empty.id}", text: "What can you do?"
  end

  test "on a narrow screen a long title and the working controls stay on the page, and the box shrinks once sent" do
    busy = create_conversation(@bot, durable_id: "14")
    busy.update!(title: "What time is it for me right now? After checking, write three short paragraphs")
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

    assert_selector ".chat__status", text: "Working…"
    assert_button "Stop"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth"), :<=, 0

    box = find("#composer textarea")
    one_line = box.evaluate_script("this.offsetHeight")
    box.send_keys("First line", [ :shift, :enter ], "second line", [ :shift, :enter ], "third line")
    assert_operator box.evaluate_script("this.offsetHeight"), :>, one_line
    sent_with = find("#composer input[name=request_id]", visible: false).value
    box.send_keys(:enter)
    assert_selector "#messages > [data-pending]", text: "third line"
    assert_equal one_line, box.evaluate_script("this.offsetHeight")
    # Typing on at once: the server renews only the request id, so nothing typed is lost.
    box.send_keys("And then")
    assert_no_selector "#composer input[name=request_id][value='#{sent_with}']", visible: false
    assert_equal "And then", box.value
    # While the bot works, Enter steered it; Queue waits for it to finish.
    assert_requested steer
    assert_button "Steer"
    box.send_keys(" this")
    click_on "Queue"
    assert_selector "#messages > [data-pending]", text: "And then this"
    assert_requested queue
  ensure
    page.current_window.resize_to(1400, 1400)
  end
end
