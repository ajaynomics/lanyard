require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Every card waiting on the person is reachable from the line above the box,
# however far back in the thread it was asked: the line links to the card's
# own page (approvals/show), which loads it alone with its real controls, and
# only for the person whose card it is.
class NeedsYouReachTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @user.agents.sole
    @conversation = create_conversation(@agent)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12\?}).to_return(body: { status: "done", failure: nil, pendingInputs: [], queued: [] }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "a question older than a page of turns is named above the box, and its link opens it with its answer form" do
    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_q", "name" => "ask_person" } ])
    (Conversation::Page::SIZE + 5).times { |index| @conversation.messages.create!(entry_key: "e#{index + 2}", entry_id: index + 2, role: "user", content: "Turn #{index}") }
    question = waiting("ask_person", { "question" => "Which day?", "options" => %w[ Monday Tuesday ] }, call_id: "toolu_q")
    approval = waiting("forget_note", { "key" => "trip" }, call_id: "toolu_f")

    get conversation_path(@conversation)

    assert_response :success
    assert_select "##{question.dom_target}", count: 0, message: "the card's turn is not on the first page"
    assert_select ".needs-you a[href=?]", approval_path(question), text: /Which day\?/
    assert_select ".needs-you", text: /and 1 more/
    assert_select ".needs-you a[href^='#']", count: 0
    assert_select ".needs-you form", count: 0, message: "the card's own page answers it, with every choice"

    get approval_path(question)
    assert_select "form[action=?]", conversation_invocation_answer_path(@conversation, question)
    assert_select "input[type=radio][value=Monday]"

    get approval_path(approval)
    assert_select "form[action=?] button", conversation_invocation_approval_path(@conversation, approval), text: "Allow once"
  end

  test "an answered card's page shows where it stands, without its controls" do
    question = waiting("ask_person", { "question" => "Which day?" }, call_id: "toolu_q")
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/12/wakes}).to_return(body: { rung: true }.to_json)

    post conversation_invocation_answer_path(@conversation, question), params: { answer: { text: "Monday" } }
    get approval_path(question)

    assert_response :success
    assert_select "##{question.dom_target}[data-state=approved]"
    assert_select "form[action=?]", conversation_invocation_answer_path(@conversation, question), count: 0
  end

  test "another person's card is not found by its address" do
    mallory = create_user(name: "Mallory")
    theirs = create_conversation(mallory.agents.sole, durable_id: "99")
    card = waiting("ask_person", { "question" => "Their secret?" }, conversation: theirs, call_id: "toolu_m")

    get approval_path(card)

    assert_response :not_found
    assert_select "form[action=?]", conversation_invocation_answer_path(theirs, card), count: 0
  end

  private
    def waiting(tool, arguments, conversation: @conversation, call_id:)
      digest = Invocation.digest_for(conversation, task_id: 7, call_id: call_id, tool: tool, arguments: arguments)
      Invocation.receive(conversation, task_id: 7, call_id: call_id, tool: tool, arguments: arguments, digest: digest)
      conversation.invocations.find_by!(call_id: call_id).tap { assert it.awaiting_person?, "#{tool} should wait for the person" }
    end
end
