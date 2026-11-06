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
    find("#composer textarea").send_keys("Thanks!", :enter)
    assert_selector "#composer textarea" do |box| box.value.empty? end
    assert_requested submit
    assert_equal "Thanks!", @conversation.reload.title
  end
end
