require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include ActionCable::TestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_sidecar_settings }

  test "the page admits the thread the first time, with the agent's scope and the sidecar token, and never again" do
    thread = @agent.conversation
    admission = stub_request(:post, "#{SIDECAR}/v1/conversations")
      .with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" },
            body: { requestId: "thread", actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s })
      .to_return(status: 201, body: { id: 12 }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(status: 503, body: { error: "not_ready" }.to_json)

    2.times { get conversation_path(thread) }

    assert_response :ok
    assert_requested admission, times: 1
    assert_equal "12", thread.reload.durable_id
  end

  test "a sidecar conversation already filed under another of the agent's conversations is refused, not guessed" do
    thread = @agent.conversation
    @agent.conversations.create!(user: @agent.user, parent: thread, root: thread, request_id: "branch", durable_id: "12")
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: 12 }.to_json)

    get conversation_path(thread)

    assert_response :ok
    assert_select ".flash", /showing what was saved/
    assert_nil thread.reload.durable_id
  end

  test "the list is every one of the person's agents, by its thread, not its branches" do
    lisbon = create_conversation(@agent)
    name_agent(lisbon.agent, "Lisbon trip")
    @agent.conversations.create!(user: @agent.user, parent: lisbon, root: lisbon, request_id: "b", durable_id: "13", title: "A branch")
    other = create_conversation(@agent, durable_id: "14")
    name_agent(other.agent, "Groceries")

    get conversations_path

    assert_select "#conversations .conversation-row__name", text: "Lisbon trip"
    assert_select "#conversations .conversation-row__name", text: "Groceries"
    assert_select "#conversations .conversation-row__name", text: "A branch", count: 0
  end

  test "another person's agent and conversations are not found" do
    mallory = create_user(name: "Mallory")
    theirs = create_conversation(mallory.agents.sole, durable_id: "99")

    get conversation_path(theirs)
    assert_response :not_found
    get agent_path(mallory.agents.sole)
    assert_response :not_found
    get conversations_path
    assert_select "a[href=?]", conversation_path(theirs), count: 0
  end

  test "a message carries the agent's current definition" do
    conversation = create_conversation(@agent)
    stub = stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .with { |request| JSON.parse(request.body).values_at("content", "requestId") == [ "Hello there", "m-1" ] &&
              JSON.parse(request.body)["definition"]["digest"] == @agent.conversation.definition[:digest] }
      .to_return(status: 202, body: { id: 1 }.to_json)

    post conversation_submissions_path(conversation), params: { content: "Hello there", request_id: "m-1" }

    assert_requested stub
    assert_equal "Assistant", conversation.reload.to_s
    assert_equal @agent.conversation.definition[:digest], conversation.definition_digest
  end

  test "an unreachable sidecar is a polite message, not an error page" do
    conversation = create_conversation(@agent)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_timeout

    post conversation_submissions_path(conversation), params: { content: "Hello", request_id: "m-2" }

    assert_redirected_to root_path
    follow_redirect!
    assert_equal "The agent is not reachable right now. Try again shortly.", flash[:alert]
  end

  test "a person approves a waiting call and the sidecar's doorbell is rung after commit" do
    conversation = create_conversation(@agent)
    @agent.notes.remember("old", "x")
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
    assert_equal @agent.user, invocation.approval.decided_by
    assert_requested wake
  end

  test "a request is decided only by its own kind of answer: a question is not approved, an approval is not answered" do
    conversation = create_conversation(@agent)
    question = { "question" => "Which day?", "options" => %w[ Monday Tuesday ] }
    Invocation.receive(conversation, task_id: 7, call_id: "toolu_1", tool: "ask_person", arguments: question,
      digest: invocation_payload(conversation, tool: "ask_person", arguments: question)[:digest])
    asked = conversation.invocations.find_by!(call_id: "toolu_1")
    Invocation.receive(conversation, task_id: 7, call_id: "toolu_2", tool: "forget_note", arguments: { "key" => "old" },
      digest: invocation_payload(conversation, tool: "forget_note", arguments: { "key" => "old" }, call_id: "toolu_2")[:digest])
    approval = conversation.invocations.find_by!(call_id: "toolu_2")

    post conversation_invocation_approval_path(conversation, asked), params: { decision: "approve" }
    assert_equal "That request has already been answered or has expired.", flash[:alert]
    post conversation_invocation_answer_path(conversation, approval), params: { answer: { text: "yes" } }
    assert_equal "That request has already been answered or has expired.", flash[:alert]
    assert asked.reload.awaiting_person?
    assert approval.reload.awaiting_person?
  end

  test "the page pulls what the sidecar committed, then shows messages and the call waiting for the person" do
    conversation = create_conversation(@agent)
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

  test "the thread reads as Messages: the person's words in the accent, the agent's grey, and the time between turns an hour apart" do
    conversation = create_conversation(@agent)
    start = 3.hours.ago
    [ [ "user", "Morning", start ], [ "assistant", "Hello.", start + 1.minute ],
      [ "user", "Still there?", start + 2.hours ], [ "assistant", "Yes.", start + 2.hours + 1.minute ] ].each.with_index(1) do |(role, content, at), index|
      conversation.messages.create!(entry_key: index.to_s, entry_id: index, role: role, content: content, created_at: at)
    end
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_timeout

    get conversation_path(conversation)

    assert_select "html[style=?]", "--accent-hue: 255"
    assert_select "#messages .ui-message[data-role=user] .ui-bubble[data-variant=primary]", count: 2
    assert_select "#messages .ui-message[data-role=assistant] .ui-bubble[data-variant=secondary] .ui-markdown", count: 2
    times = css_select("#messages > .ui-time time").map { Time.iso8601(it["datetime"]) }
    assert_equal [ start, start + 2.hours ].map(&:to_i), times.map(&:to_i), "a time before the first turn and before the one two hours on"
  end

  test "a broadcast turn says when only after an hour's quiet" do
    conversation = create_conversation(@agent)
    conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Hi", created_at: 2.hours.ago)
    soon = conversation.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "Hello.", created_at: 2.hours.ago + 5.minutes)
    later = conversation.messages.create!(entry_key: "3", entry_id: 3, role: "user", content: "Back again")

    assert_no_match "ui-time", ApplicationController.render(partial: "messages/message", locals: { message: soon })
    assert_match "ui-time", ApplicationController.render(partial: "messages/message", locals: { message: later })
  end

  test "an unreachable sidecar still shows the saved copy" do
    conversation = create_conversation(@agent)
    conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Saved earlier")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_timeout

    get conversation_path(conversation)

    assert_response :ok
    assert_select ".ui-bubble", "Saved earlier"
    assert_select ".flash", /showing what was saved/
  end

  test "a message the sidecar refuses says why, and keeps the text to try again" do
    conversation = create_conversation(@agent)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 422, body: { error: "computer_unavailable" }.to_json)

    post conversation_submissions_path(conversation), params: { content: "Run ls", request_id: "req-9" }, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_select "turbo-stream[action=update][target=flash] template", /computer is not available here/
    assert_select "turbo-stream[target=composer]", count: 0
  end

  # A 1x1 PNG, made here rather than kept as a fixture.
  PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
  def picture(bytes = PNG, type: "image/png", name: "dot.png") = Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: name)

  test "pictures go to the sidecar as image blocks after the words, typed by their bytes, and are not stored here" do
    conversation = create_conversation(@agent)
    sent = nil
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").with { sent = JSON.parse(it.body) }.to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(body: { entries: [], cursor: nil, more: false }.to_json)

    post conversation_submissions_path(conversation), params: { content: "What is this?", request_id: "m-3",
      images: [ picture, picture(type: "image/jpeg", name: "dot.jpg") ] }, as: :turbo_stream

    assert_response :success
    image = { "type" => "image", "data" => Base64.strict_encode64(PNG), "mimeType" => "image/png" }
    assert_equal [ { "type" => "text", "text" => "What is this?" }, image, image ], sent["content"]
    assert_equal 0, ActiveStorage::Blob.count
    assert_select "turbo-stream[action=update][target=composer_error]"
  end

  test "pictures alone are a message" do
    conversation = create_conversation(@agent)
    sent = nil
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").with { sent = JSON.parse(it.body) }.to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(body: { entries: [], cursor: nil, more: false }.to_json)

    post conversation_submissions_path(conversation), params: { request_id: "m-4", images: [ picture ] }, as: :turbo_stream

    assert_equal [ "image" ], sent["content"].pluck("type")
  end

  test "nothing at all is not a message" do
    conversation = create_conversation(@agent)

    post conversation_submissions_path(conversation), params: { content: "", request_id: "m-5" }, as: :turbo_stream

    assert_response :bad_request
  end

  test "too many, too large or not a picture: the composer says why and nothing is sent" do
    conversation = create_conversation(@agent)
    refused = {
      "Attach up to 4 pictures to one message." => Array.new(5) { picture },
      "Each picture must be 5 MB or smaller." => [ picture(PNG + ("\0" * 5.megabytes)) ],
      "Only PNG, JPEG, WebP and GIF pictures can be sent." => [ picture("<svg xmlns='http://www.w3.org/2000/svg'/>", name: "fake.png") ]
    }
    refused.each_with_index do |(reason, images), index|
      post conversation_submissions_path(conversation), params: { content: "Look", request_id: "bad-#{index}", images: images }, as: :turbo_stream

      assert_response :unprocessable_entity
      assert_select "turbo-stream[action=update][target=composer_error] template", reason
    end
  end

  test "a model that cannot look at pictures is refused in the composer, in plain words" do
    conversation = create_conversation(@agent)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 422, body: { error: "images_unsupported" }.to_json)

    post conversation_submissions_path(conversation), params: { content: "Look", request_id: "m-6", images: [ picture ] }, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_select "turbo-stream[action=update][target=composer_error] template", /model can't look at pictures/
  end

  test "an agent's name can't be changed from its thread, which has no pencil" do
    conversation = create_conversation(@agent)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(status: 503, body: { error: "unavailable" }.to_json)

    get conversation_path(conversation)
    assert_select "#rename_form", count: 0

    patch conversation_path(conversation), params: { conversation: { title: "Lisbon trip" } }
    assert_response :not_found
    assert_equal "Assistant", @agent.reload.name
  end

  test "a branch can be renamed, the owner's alone, and the agent it came from keeps its name" do
    conversation = create_conversation(@agent)
    branch = @agent.conversations.create!(user: @agent.user, request_id: "b-4", durable_id: "43", parent: conversation, title: "Assistant (branch)")
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/43}).to_return(status: 503, body: { error: "unavailable" }.to_json)

    get conversation_path(branch)
    assert_select "#rename_form input[name='conversation[title]'][value=?]", "Assistant (branch)"

    streams = capture_turbo_stream_broadcasts(branch) do
      patch conversation_path(branch), params: { conversation: { title: "Lisbon, the cheaper week" } }
    end
    assert_redirected_to conversation_path(branch)
    assert_equal "Lisbon, the cheaper week", branch.reload.to_s
    assert_equal "Assistant", @agent.reload.name
    assert_includes streams.map { it["target"] }, "title_conversation_#{branch.id}"

    patch conversation_path(branch), params: { conversation: { title: "x" * 201 } }
    assert_equal "A branch's name must be 1 to 200 characters.", flash[:alert]
    assert_equal "Lisbon, the cheaper week", branch.reload.to_s

    theirs = create_user(name: "Mallory").agents.sole
    their_branch = theirs.conversations.create!(user: theirs.user, request_id: "b-9", parent: theirs.conversation)
    patch conversation_path(their_branch), params: { conversation: { title: "Mine now" } }
    assert_response :not_found
  end

  test "/model and /thinking change the agent and go back to the conversation" do
    conversation = create_conversation(@agent)
    level = (%w[ low high ] - [ @agent.thinking_level ]).first

    patch agent_path(@agent), params: { command: "thinking", agent: { thinking_level: level } }, headers: { "Referer" => conversation_url(conversation) }
    assert_redirected_to conversation_url(conversation)
    assert_equal level, @agent.reload.thinking_level
    assert_equal "Saved. Assistant uses this from the next message.", flash[:notice]

    patch agent_path(@agent), params: { command: "model", agent: { model: "someone/else" } }, headers: { "Referer" => conversation_url(conversation) }
    assert_redirected_to conversation_url(conversation)
    assert_match(/No model matches “someone\/else”/, flash[:alert])

    theirs = create_user(name: "Mallory").agents.sole
    patch agent_path(theirs), params: { command: "thinking", agent: { thinking_level: "off" } }
    assert_response :not_found
  end
end
