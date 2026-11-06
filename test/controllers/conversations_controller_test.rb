require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_sidecar_settings }

  test "admission is idempotent and carries the bot's scope with the sidecar token" do
    stub = stub_request(:post, "#{SIDECAR}/v1/conversations")
      .with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" },
            body: { requestId: "req-1", actorId: @bot.user_id.to_s, workspaceId: @bot.id.to_s })
      .to_return(status: 201, body: { id: 12 }.to_json)

    2.times { post bot_conversations_path(@bot), params: { request_id: "req-1" } }

    assert_requested stub, times: 2
    assert_redirected_to conversation_path(@bot.conversations.sole)
    assert_equal "12", @bot.conversations.sole.durable_id
  end

  test "a sidecar conversation already mapped to another request is a conflict, not a guess" do
    create_conversation(@bot, durable_id: "12", request_id: "earlier")
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: 12 }.to_json)

    post bot_conversations_path(@bot), params: { request_id: "later" }

    assert_response :conflict
    assert_equal 1, @bot.conversations.count
  end

  test "another person's bot and conversations are not found" do
    mallory = create_user(name: "Mallory")
    theirs = create_conversation(mallory.bots.sole, durable_id: "99")

    get conversation_path(theirs)
    assert_response :not_found
    get bot_conversations_path(mallory.bots.sole)
    assert_response :not_found
  end

  test "a message carries the bot's current definition" do
    conversation = create_conversation(@bot)
    stub = stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .with { |request| JSON.parse(request.body).values_at("content", "requestId") == [ "Hello there", "m-1" ] &&
              JSON.parse(request.body)["definition"]["digest"] == @bot.definition[:digest] }
      .to_return(status: 202, body: { id: 1 }.to_json)

    post conversation_submissions_path(conversation), params: { content: "Hello there", request_id: "m-1" }

    assert_requested stub
    assert_equal "Hello there", conversation.reload.title
    assert_equal @bot.definition[:digest], conversation.definition_digest
  end

  test "an unreachable sidecar is a polite message, not an error page" do
    conversation = create_conversation(@bot)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_timeout

    post conversation_submissions_path(conversation), params: { content: "Hello", request_id: "m-2" }

    assert_redirected_to root_path
    follow_redirect!
    assert_equal "The assistant is not reachable right now. Try again shortly.", flash[:alert]
  end

  test "a person approves a waiting call and the sidecar's doorbell is rung after commit" do
    conversation = create_conversation(@bot)
    @bot.notes.remember("old", "x")
    payload = invocation_payload(conversation, tool: "forget_note", arguments: { "key" => "old" })
    Invocation.receive(conversation, task_id: 7, call_id: "toolu_1", tool: "forget_note", arguments: { "key" => "old" }, digest: payload[:digest])
    invocation = conversation.invocations.sole
    wake = stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes")
      .with(body: hash_including(key: "7:toolu_1")).to_return(status: 200, body: { rung: true }.to_json)

    perform_enqueued_jobs do
      post conversation_invocation_approval_path(conversation, invocation), params: { decision: "approve" }
    end

    assert_redirected_to conversation_path(conversation)
    assert invocation.reload.approved?
    assert_equal @bot.user, invocation.approval.decided_by
    assert_requested wake
  end

  test "the page pulls what the sidecar committed, then shows messages and the call waiting for the person" do
    conversation = create_conversation(@bot)
    payload = invocation_payload(conversation, tool: "forget_note", arguments: { "key" => "old" }, call_id: "call_9")
    Invocation.receive(conversation, task_id: 7, call_id: "call_9", tool: "forget_note", arguments: { "key" => "old" }, digest: payload[:digest])
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "waiting", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [
        { id: "1", entryId: 1, role: "user", content: "Forget the old note" },
        { id: "2", entryId: 2, role: "assistant", content: "Sure.[tool: forget_note]", toolCalls: [ { id: "call_9", name: "forget_note" } ] }
      ], cursor: 2, more: false }.to_json)

    get conversation_path(conversation)

    assert_response :ok
    assert_select ".ui-message[data-align=end] .ui-bubble", "Forget the old note"
    assert_select ".ui-message[data-role=assistant] .ui-markdown", "Sure."
    assert_select "##{Invocation.dom_target('call_9')} .approval .ui-card__title", "Allow forget note?"
    assert_select "#composer textarea[name=content]"
    assert_select ".flash", count: 0
    assert_select "#status_conversation_#{conversation.id}[data-status=waiting]"
  end

  test "an unreachable sidecar still shows the saved copy" do
    conversation = create_conversation(@bot)
    conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Saved earlier")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_timeout

    get conversation_path(conversation)

    assert_response :ok
    assert_select ".ui-bubble", "Saved earlier"
    assert_select ".flash", /showing what was saved/
  end

  test "a message the sidecar refuses says why, and keeps the text to try again" do
    conversation = create_conversation(@bot)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 422, body: { error: "computer_unavailable" }.to_json)

    post conversation_submissions_path(conversation), params: { content: "Run ls", request_id: "req-9" }, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_select "turbo-stream[action=update][target=flash] template", /computer is not available here/
    assert_select "turbo-stream[target=composer]", count: 0
  end
end
