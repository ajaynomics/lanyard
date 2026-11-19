require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# A busy thread waiting on the person: messages keep arriving, and the card
# stays within reach and the thread stays waiting.
class ThreadWaitingTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    @agent.notes.remember("old", "x")
    @agent.notes.remember("older", "y")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "waiting", failure: nil, pendingInputs: [], queued: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .to_return { |request| @submissions << JSON.parse(request.body); { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes").to_return(body: { rung: true }.to_json)
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Clearing the old notes.",
      tool_calls: [ { "id" => "call_1", "name" => "forget_note" }, { "id" => "call_2", "name" => "forget_note" } ])
    card "call_1", "old"
  end

  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "Campfire mail arriving while a card waits leaves the thread waiting, in one line, and the card named above the box" do
    visit conversation_path(@conversation)
    wait_for_live_updates
    assert_selector ".needs-you a[href='#{approval_path(invocation("call_1"))}']", text: "Needs you · Allow forget note?"

    @conversation.receive("Can you check the parking?\nBefore Friday, please.", from: "Maya in Trips", via: "Campfire",
      answer: "Answer in the room.", request_id: "campfire:1", when_busy: "steer")
    @conversation.receive_frame(seq: 5, busy: true, tail: "", failure: nil, queued: [
      { "id" => "31", "mode" => "steer", "text" => @submissions.sole["content"], "pictures" => 0 },
      { "id" => "32", "mode" => "steer", "text" => "Rome, not Paris", "pictures" => 0 }
    ])

    assert_selector ".message__queued-other summary", text: "Maya in Trips · Campfire · Can you check the parking?"
    assert_no_text "Before Friday, please."
    # An approval holds no steer: its call hands the card back to Rails, and the agent reads it next.
    assert_selector ".message--queued", text: "Steering · #{@agent} reads this after its current step"
    assert_selector ".chat__status[data-status=waiting]"
    assert_no_selector ".ui-typing"
  end

  test "allowing one of two cards through the line above the box leaves the thread waiting on the other" do
    card "call_2", "older"
    @conversation.receive_frame(seq: 1, busy: true, tail: "", failure: nil)
    visit conversation_path(@conversation)
    assert_selector ".needs-you", text: "and 1 more"
    assert_no_selector ".needs-you button"

    find(".needs-you a").click
    assert_current_path approval_path(invocation("call_1"))
    click_on "Allow once"

    # The card's page answers as Needs you does: back to the list, which says so and names the other.
    assert_current_path approvals_path
    assert_text "Allowed."
    assert_selector "#approvals a[href='#{approval_path(invocation("call_2"))}']"
    visit conversation_path(@conversation)
    assert_selector ".needs-you a[href='#{approval_path(invocation("call_2"))}']"
    assert_no_selector ".needs-you", text: "and 1 more"
    assert_selector ".chat__status[data-status=waiting]", text: "Waiting for you"
    assert_equal "waiting", @conversation.reload.status
  end

  test "a helper's question after the agent finished is answered from the line above the box, and the thread goes idle, not working" do
    @conversation.helpers.create!(call_id: "call_h", task: "Find a hotel.")
    invocation("call_1").update!(state: "denied")
    @conversation.invocations.create!(task_id: "7", call_id: "call_h/toolu_q", tool_name: "ask_person", digest: "q",
      arguments: { "question" => "Which hotel?" }, state: "awaiting_person", expires_at: 1.hour.from_now)
    @conversation.receive_frame(seq: 1, busy: false, tail: "", failure: nil)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "done", failure: nil, pendingInputs: [], queued: [] }.to_json)

    visit conversation_path(@conversation)
    assert_selector ".chat__status[data-status=waiting]", text: "Waiting for you"
    find(".needs-you a", text: "Which hotel?").click
    fill_in "Your answer", with: "The Larch"
    click_on "Answer"

    assert_current_path conversation_path(@conversation)
    assert_selector ".chat__status[data-status=idle]"
    assert_no_selector ".needs-you a"
    assert_no_selector ".ui-typing"
    assert_equal %w[ idle idle ], @conversation.reload.values_at(:status, :execution_status)
  end

  private
    def invocation(call_id) = @conversation.invocations.find_by!(call_id: call_id)

    def card(call_id, key)
      payload = invocation_payload(@conversation, tool: "forget_note", arguments: { "key" => key }, call_id: call_id)
      Invocation.receive(@conversation, task_id: 7, call_id: call_id, tool: "forget_note", arguments: payload[:arguments], digest: payload[:digest])
    end
end
