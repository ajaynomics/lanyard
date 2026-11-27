require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A helper the agent started in the background (Helper): the sidecar reports
# that it is working, then how it ended, and its answer comes to the thread
# once. A person sees it on its line and may cancel it; the agent hears of a
# cancel with whatever it is told next, without a turn of its own.
class BackgroundHelpersTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActionCable::TestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @submissions = []
    @cancels = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return { |request|
      @cancels << JSON.parse(request.body)
      { body: { cancelled: true, count: 3, tools: [
        { callId: "a", name: "bash", status: "done", output: "ok" }, { callId: "b", name: "bash", status: "done", output: "ok" },
        { callId: "c", name: "send_email", status: "stopped", output: "" } ] }.to_json } }
  end
  teardown { remove_sidecar_settings }

  test "a person tells a working helper something: it reaches the helper, shows on its card, and goes to the agent with the answer" do
    report state: "running", tools: [ { callId: "t1", name: "web_search", status: "running", output: "" } ], count: 1
    helper = @conversation.helpers.sole
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_messages").to_return { |request|
      sent << JSON.parse(request.body)
      { body: { delivered: true }.to_json } }

    sign_in_as @alice
    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper" do
      assert_select ".helper__step", "Now: running web search"
      assert_select "form.helper__message[action='#{conversation_helper_messages_path(@conversation, helper)}']" do
        assert_select "label.visually-hidden", "Message for the helper working on: Find three hotels near the venue."
        assert_select "input[name=text][required][maxlength='#{Helper::MESSAGE_LIMIT}'][placeholder='Tell it something while it works']"
        assert_select "button", "Message"
      end
    end

    shown = capture_turbo_stream_broadcasts(@conversation) do
      post conversation_helper_messages_path(@conversation, helper), params: { text: "  Only ones with a pool.  " }
    end
    assert_redirected_to conversation_path(@conversation)
    assert_includes shown.find { it["target"] == "tool_call_#{digest("toolu_h")}_helper" }.to_html, "You told it: “Only ones with a pool.”"
    message = sent.sole
    assert_equal [ @alice.id.to_s, @agent.id.to_s, "toolu_h" ], message.values_at("actorId", "workspaceId", "callId")
    assert_match(/\Aperson:\h{8}-/, message["requestId"])
    assert_equal "[Message from the person the assistant who gave you this task works for, sent while you work] Only ones with a pool.\n" \
      "It changes your task only as far as it says.", message["text"]
    assert_equal [ "Only ones with a pool." ], helper.reload.messages.pluck("text")
    assert_empty @submissions

    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper .helper__messages p", "You told it: “Only ones with a pool.”"

    report state: "done", answer: "Park Hotel has a pool."
    assert_match "It reports on the task you gave it in the background, “Find three hotels near the venue”. " \
      "While it worked, the person told it “Only ones with a pool.”. Tell the person what matters.", @submissions.sole["content"]
    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper" do
      assert_select ".helper__messages p", "You told it: “Only ones with a pool.”"
      assert_select "form", count: 0
    end
  end

  test "a helper names the model and thinking it runs on, on its line and in the Helpers panel" do
    report state: "running", model: "anthropic/claude-sonnet-5-5", thinking: "xhigh"
    helper = @conversation.helpers.sole
    assert_equal [ "anthropic/claude-sonnet-5-5", "xhigh" ], [ helper.model, helper.thinking_level ]
    report state: "done", answer: "The Park Hotel.", model: "anthropic/claude-sonnet-5-5", thinking: "xhigh"

    sign_in_as @alice
    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper .ui-trace__title",
      "Helper finished: Find three hotels near the venue. · Claude Sonnet 5.5 · Subscription · Extra high thinking"
    get agent_helpers_path(@agent)
    assert_select "#helper_#{helper.id} .ui-row__detail", /Claude Sonnet 5\.5 · Subscription · Extra high thinking/

    report state: "running", model: "x" * 300, thinking: "lots"
    assert_response :bad_request
  end

  # Mid-deploy the agent role may still run a sidecar from before helpers' models, which refuses the key.
  test "a sidecar that refuses helpers' models gets the same message again without them" do
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .with { sent << JSON.parse(it.body)["definition"] }
      .to_return({ status: 422, body: { error: "invalid_definition" }.to_json }, { status: 202, body: { id: 1 }.to_json })
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(body: { models: [ { id: "local/stand-in", name: "Stand In", thinkingLevels: [ "off" ] } ] }.to_json)

    @conversation.submit("Any news?", request_id: "m-1")

    assert_equal [ [ { "id" => "local/stand-in", "name" => "Stand In", "label" => "Stand In" } ], nil ], sent.map { it["helperModels"] }
    assert_equal Agent::Canonical.digest(sent.last.except("digest")), sent.last["digest"]
    assert_equal sent.last["digest"], @conversation.reload.definition_digest
  end

  test "a helper that finished takes no message, whether Rails or the sidecar knew first" do
    report state: "running"
    helper = @conversation.helpers.sole
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_messages").to_return(body: { delivered: false }.to_json)

    sign_in_as @alice
    post conversation_helper_messages_path(@conversation, helper), params: { text: "Only ones with a pool." }
    assert_redirected_to conversation_path(@conversation)
    assert_equal "That helper had already finished, so it didn't get your message.", flash[:alert]
    assert_empty helper.reload.messages

    report state: "done", answer: "Done."
    post conversation_helper_messages_path(@conversation, helper), params: { text: "And breakfast?" }
    assert_equal "That helper had already finished, so it didn't get your message.", flash[:alert]
    assert_requested :post, "#{SIDECAR}/v1/conversations/12/helper_messages", times: 1

    post conversation_helper_messages_path(@conversation, helper), params: { text: "" }
    assert_response :bad_request
  end

  test "a working helper shows on its line with Cancel, and in the status line" do
    started = capture_turbo_stream_broadcasts(@conversation) do
      report state: "running", tools: [ { callId: "t1", name: "web_search", status: "running", output: "" } ], count: 4.5
    end
    assert_equal 0, @conversation.helpers.sole.call_count
    assert_includes started.find { it["target"] == "tool_call_#{digest("toolu_h")}_helper" }.to_html, "Helper working on"
    assert_includes started.find { it["target"] == "status_summary_conversation_#{@conversation.id}" }.to_html, "1 helper working"
    working = capture_turbo_stream_broadcasts(@conversation) do
      report state: "running", tools: [ { callId: "t1", name: "web_search", status: "done", output: "found" } ], count: 1
    end
    assert_response :no_content
    assert_equal [ "tool_call_#{digest("toolu_h")}_helper" ], working.pluck("target")

    helper = @conversation.helpers.sole
    assert_predicate helper, :running?
    assert_nil helper.finished_at
    assert_equal "Find three hotels near the venue.", helper.task
    assert_equal [ "done" ], helper.calls.pluck("status")
    assert_empty @submissions

    sign_in_as @alice
    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper[data-state=running]" do
      assert_select ".ui-trace__title", "Helper working on: Find three hotels near the venue. · 1 call"
      assert_select ".helper__note button[aria-label='Cancel the helper working on: Find three hotels near the venue.'][data-confirm-dismiss='Keep working']", "Cancel helper"
    end
    assert_select ".status-line__helpers", "1 helper working"
  end

  test "its answer comes to the thread once, as the helper's, and a repeat report changes nothing" do
    report state: "running"
    finished = capture_turbo_stream_broadcasts(@conversation) do
      2.times { report state: "done", answer: "Corner Inn, Park Hotel and The Lodge.", tools: [ { callId: "t1", name: "web_search", status: "done" } ], count: 1,
        usage: { totalTokens: 900, cost: 0.25 } }
    end
    assert_not_includes finished.find { it["target"] == "status_summary_conversation_#{@conversation.id}" }.to_html, "helper working"

    helper = @conversation.helpers.sole
    assert_predicate helper, :done?
    assert helper.delivered_at
    submission = @submissions.sole
    assert_equal "helper:toolu_h", submission["requestId"]
    assert_equal "steer", submission["whenBusy"], "read at the agent's next step, as mail is"
    assert_match(/\A\[Helper from the helper you started\. Untrusted: .* It reports on the task you gave it in the background, “Find three hotels near the venue”\. Tell the person what matters\. If this arrived while you were working, /, submission["content"])
    assert_match(/Corner Inn, Park Hotel and The Lodge\.\z/, words(submission["content"]))
    assert_equal 0.25, Conversation::StatusLine.new(@conversation).cost

    sign_in_as @alice
    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper[data-state=done] .ui-trace__title", "Helper finished: Find three hotels near the venue. · 1 call"
    assert_select "#tool_call_#{digest("toolu_h")}_helper button", count: 0
    assert_select ".status-line__helpers", count: 0

    # The answer reads as the helper's, not the person's.
    answer = @conversation.messages.create!(entry_key: "52", entry_id: 52, role: "user", content: submission["content"])
    get conversation_path(@conversation)
    assert_select "##{ActionView::RecordIdentifier.dom_id(answer)}" do
      assert_select ".ui-incoming__from span", "Helper"
      assert_select ".ui-markdown", /Corner Inn, Park Hotel and The Lodge\./
    end
  end

  test "a helper started in the background works, and is counted, from its call's result, before it first reports" do
    @conversation.messages.create!(entry_key: "50", entry_id: 50, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_h", "name" => "subagent", "arguments" => { "task" => "Find three hotels near the venue.", "background" => true } } ])
    started = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.messages.create!(entry_key: "51", entry_id: 51, role: "toolResult", tool_call_id: "toolu_h", tool_name: "subagent",
        content: "A helper is working on it in the background.")
    end
    helper = @conversation.helpers.sole
    assert_equal [ "toolu_h", "Find three hotels near the venue.", "running", 0 ], [ helper.call_id, helper.task, helper.state, helper.call_count ]
    assert_includes started.find { it["target"] == "status_summary_conversation_#{@conversation.id}" }.to_html, "1 helper working"
    assert_includes started.select { it["target"] == "tool_call_#{digest("toolu_h")}_helper" }.last.to_html, "Cancel helper"

    # Its first report finds it, and a report that came first is found by the result.
    report state: "running", count: 1
    assert_equal helper, @conversation.helpers.sole
    report callId: "toolu_early", state: "running", task: "Read the menu."
    @conversation.messages.create!(entry_key: "52", entry_id: 52, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_early", "name" => "subagent", "arguments" => { "task" => "Read the menu.", "background" => true } } ])
    @conversation.messages.create!(entry_key: "53", entry_id: 53, role: "toolResult", tool_call_id: "toolu_early", tool_name: "subagent", content: "Working.")
    assert_equal 2, @conversation.helpers.running.count

    # A helper in the foreground, and a start refused, are not counted.
    @conversation.messages.create!(entry_key: "54", entry_id: 54, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_f", "name" => "subagent", "arguments" => { "task" => "Read the report." } },
                    { "id" => "toolu_r", "name" => "subagent", "arguments" => { "task" => "One too many.", "background" => true } } ])
    @conversation.messages.create!(entry_key: "55", entry_id: 55, role: "toolResult", tool_call_id: "toolu_f", tool_name: "subagent", content: "It says yes.")
    @conversation.messages.create!(entry_key: "56", entry_id: 56, role: "toolResult", tool_call_id: "toolu_r", tool_name: "subagent", error: true,
      content: "3 helpers are already working in this conversation, the most at once.")
    assert_equal %w[ toolu_early toolu_h ], @conversation.helpers.reload.pluck(:call_id).sort
  end

  test "a helper in the foreground keeps its own line" do
    @conversation.messages.create!(entry_key: "50", entry_id: 50, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_f", "name" => "subagent", "arguments" => { "task" => "Read the report." } } ])
    @conversation.messages.create!(entry_key: "51", entry_id: 51, role: "toolResult", tool_call_id: "toolu_f", tool_name: "subagent", content: "It says yes.")

    sign_in_as @alice
    get conversation_path(@conversation)
    assert_select "##{Invocation.dom_target("toolu_f")} > .ui-trace .ui-trace__title", "Helper: Read the report."
    assert_select "#tool_call_#{digest("toolu_f")}_helper", count: 0
  end

  test "an answer Rails could not hand in is handed in when the sidecar tells it again" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 503, body: { error: "unavailable" }.to_json).then
      .to_return { |request| @submissions << JSON.parse(request.body); { status: 202, body: { id: 1, status: "queued" }.to_json } }

    assert_raises(DurableAssistants::PiDurable::Client::Error) { report state: "done", answer: "Done." }
    assert_predicate @conversation.helpers.sole, :done?
    assert_nil @conversation.helpers.sole.delivered_at

    report state: "done", answer: "Done."
    assert_response :no_content
    assert_equal 1, @submissions.size
    assert @conversation.helpers.sole.delivered_at
  end

  test "a helper that failed says so, to the thread and on its line" do
    report state: "failed", reason: "request_limit"

    assert_predicate @conversation.helpers.sole, :failed?
    assert_match(/The helper stopped without an answer: it reached its limit of model requests\.\z/, words(@submissions.sole["content"]))
    sign_in_as @alice
    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper[data-state=failed]" do
      assert_select ".ui-trace__title", "Helper stopped: Find three hotels near the venue."
      assert_select "p", "It stopped without an answer: it reached its limit of model requests."
    end
  end

  test "a helper whose start was never recorded arrives with only its end, and tells the agent to start it again" do
    report state: "failed", reason: "not_recorded"

    assert_predicate @conversation.helpers.sole, :failed?
    assert_match(/The helper stopped without an answer: its start couldn't be recorded here for a day, so it never began; start it again\.\z/,
      words(@submissions.sole["content"]))
  end

  test "Cancel stops it, answers its waiting cards, says what it had done, and the agent hears with its next message" do
    report state: "running"
    waiting = @conversation.invocations.create!(task_id: "7", call_id: "toolu_h/toolu_q", tool_name: "remember_note", arguments: { "key" => "k" },
      digest: "d", state: "awaiting_person", expires_at: 1.hour.from_now)
    own = @conversation.invocations.create!(task_id: "8", call_id: "toolu_q", tool_name: "remember_note", arguments: { "key" => "k" },
      digest: "e", state: "awaiting_person", expires_at: 1.hour.from_now)
    helper = @conversation.helpers.sole

    sign_in_as @alice
    delete conversation_helper_path(@conversation, helper)
    assert_redirected_to conversation_path(@conversation)

    assert_equal [ { "actorId" => @alice.id.to_s, "workspaceId" => @agent.id.to_s, "callId" => "toolu_h" } ], @cancels
    assert_predicate helper.reload, :cancelled?
    assert_equal [ "failed", "The person cancelled the helper that asked." ], [ waiting.reload.state, waiting.error ]
    assert_predicate own.reload, :awaiting_person?
    assert_empty @submissions

    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper[data-state=cancelled]" do
      assert_select ".ui-trace[data-status=cancelled] .ui-trace__title", "Helper cancelled: Find three hotels near the venue."
      assert_select ".helper__note", "Before you cancelled it, it had run bash (2 times)."
      assert_select "button", count: 0
    end

    # Cancelled once; a report that comes after changes nothing.
    delete conversation_helper_path(@conversation, helper)
    assert_equal "That helper had already finished.", flash[:alert]
    assert_equal 1, @cancels.size
    report state: "done", answer: "Too late."
    assert_predicate helper.reload, :cancelled?
    assert_empty @submissions

    @conversation.submit("Any news?", request_id: "next")
    sent = @submissions.sole["content"]
    assert_match "<helpers_cancelled>\nThe person cancelled the helper working on “Find three hotels near the venue”. Before that it had run bash (2 times).\n</helpers_cancelled>", sent
    assert helper.reload.told_at
    @conversation.submit("And now?", request_id: "after")
    assert_no_match "helpers_cancelled", @submissions.last["content"]

    message = @conversation.messages.create!(entry_key: "90", entry_id: 90, role: "user", content: sent)
    assert_equal "Any news?", message.said
  end

  test "an approval a helper raised says it came from the helper" do
    report state: "running"
    @conversation.invocations.create!(task_id: "7", call_id: "toolu_h/toolu_f", tool_name: "forget_note",
      arguments: { "key" => "dentist" }, digest: "d", state: "awaiting_person", expires_at: 1.hour.from_now)

    @conversation.invocations.create!(task_id: "8", call_id: "toolu_own", tool_name: "forget_note",
      arguments: { "key" => "school" }, digest: "e", state: "awaiting_person", expires_at: 1.hour.from_now)
    @conversation.messages.create!(entry_key: "60", entry_id: 60, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_own", "name" => "forget_note", "arguments" => { "key" => "school" } } ])

    sign_in_as @alice
    show_thread_with_helper_call
    assert_select ".approval", count: 2
    assert_select ".approval .approval__from", count: 1
    assert_select ".approval .approval__from", "From a helper working on: Find three hotels near the venue."
  end

  test "a start refused at the limit shows on its line" do
    @conversation.messages.create!(entry_key: "50", entry_id: 50, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_h", "name" => "subagent", "arguments" => { "task" => "Find three hotels near the venue.", "background" => true } } ])
    @conversation.messages.create!(entry_key: "51", entry_id: 51, role: "toolResult", tool_call_id: "toolu_h", tool_name: "subagent", error: true,
      content: "3 helpers are already working in this conversation, the most at once. Wait for one to finish, or do it yourself.")

    sign_in_as @alice
    get conversation_path(@conversation)
    assert_select "#tool_call_#{digest("toolu_h")}_helper[data-state=failed]" do
      assert_select ".ui-trace__title", "Helper didn't start: Find three hotels near the venue."
      assert_select "p", "3 helpers are already working in this conversation, the most at once. Wait for one to finish, or do it yourself."
    end
    assert_empty @conversation.helpers
  end

  test "nobody else can see or cancel it, and the sidecar reaches it only through its own conversation" do
    report state: "running"
    helper = @conversation.helpers.sole
    mallory = create_user(name: "Mallory")

    sign_in_as mallory
    delete conversation_helper_path(@conversation, helper)
    assert_response :not_found
    post conversation_helper_messages_path(@conversation, helper), params: { text: "Stop." }
    assert_response :not_found
    assert_empty helper.reload.messages
    assert_predicate helper.reload, :running?

    post "/agent/helpers", params: payload(state: "done", answer: "x").merge(actorId: mallory.id.to_s), headers: rails_bearer, as: :json
    assert_response :forbidden
    post "/agent/helpers", params: payload(state: "done", answer: "x").merge(conversationId: "404"), headers: rails_bearer, as: :json
    assert_response :not_found
    assert_predicate helper.reload, :running?
  end

  test "deleting the agent stops its helpers still working, and one the sidecar can't stop doesn't hold the deletion up" do
    report state: "running"
    @conversation.helpers.create!(call_id: "toolu_done", task: "Done already.", state: "done")
    @agent.destroy!
    assert_equal [ "toolu_h" ], @cancels.pluck("callId")
    assert_empty Helper.where(call_id: %w[ toolu_h toolu_done ]) # tenancy-ok: what's left of a deleted agent

    other = create_conversation(@alice.personal_workspace.agents.create!(user: @alice, name: "Second", instructions: "Help.", model: @agent.model), durable_id: "13")
    other.helpers.create!(call_id: "toolu_x", task: "Look.")
    stub_request(:post, "#{SIDECAR}/v1/conversations/13/helper_cancellations").to_return(status: 503, body: { error: "unavailable" }.to_json)
    other.agent.destroy!
    assert_not Agent.exists?(other.agent_id) # tenancy-ok: the deleted agent is gone
  end

  test "a cancel keeps the last calls the sidecar names, as many as a report would" do
    report state: "running"
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return(
      body: { cancelled: true, count: 70, tools: 70.times.map { { callId: "m#{it}", name: "bash", status: "done" } } }.to_json)
    assert @conversation.helpers.sole.cancel
    assert_equal %w[ m6 m69 ], @conversation.helpers.sole.calls.values_at(0, -1).pluck("callId")
  end

  test "a finish that arrives while the sidecar cancels wins, and its answer still comes" do
    report state: "running"
    helper = @conversation.helpers.sole
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return { |request|
      helper.receive(state: "done", answer: "Just in time.")
      { body: { cancelled: false, count: 0, tools: [] }.to_json } }

    assert_equal false, helper.cancel
    assert_predicate helper.reload, :done?
    assert_match(/Just in time\.\z/, words(@submissions.sole["content"]))
  end

  test "an answer too wide for one message reaches the agent once, cut and saying so, not refused on every retry" do
    2.times do
      report state: "done", answer: "\u{1F600}" * Conversation::WORDS_LIMIT
      assert_response :no_content
    end

    content = words(@submissions.sole["content"])
    assert content.end_with?(Conversation::CUT)
    assert_operator Conversation.utf16_length(content), :<=, Conversation::WORDS_LIMIT
    assert @conversation.helpers.sole.delivered_at
  end

  test "a helper's line before its first report, and the calls it reports, kept as far as they can be read" do
    sign_in_as @alice
    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper[data-state=running] .ui-trace__title", "Helper working on: Find three hotels near the venue."
    assert_equal [ "Cancel helper", "Message" ], css_select("#tool_call_#{digest("toolu_h")}_helper button").map { it.text.strip }

    report state: "done", answer: "a" * (Conversation::WORDS_LIMIT + 10), count: 4, tools: [ "x", { callId: 1, name: "bash" }, { callId: "t1" },
      { callId: "t2", name: "bash", status: "done", output: "#{"o" * 3_000}end", arguments: { command: "x" * 5_000 } },
      { callId: "t3", name: "remember_note", status: "done", arguments: { key: "k" } } ]
    helper = @conversation.helpers.reload.sole
    assert_equal Conversation::WORDS_LIMIT, helper.answer.length
    report callId: "toolu_many", state: "running", tools: 70.times.map { { callId: "m#{it}", name: "bash", status: "done" } }
    assert_equal %w[ m6 m69 ], @conversation.helpers.find_by!(call_id: "toolu_many").calls.values_at(0, -1).pluck("callId")
    assert_equal 4, helper.call_count
    assert_equal [ { "callId" => "t2", "name" => "bash", "status" => "done", "output" => "#{"o" * 1_997}end" },
      { "callId" => "t3", "name" => "remember_note", "status" => "done", "output" => "", "arguments" => { "key" => "k" } } ], helper.calls

    # The agent's own tools show as their ledger rows, under the line; the sidecar's, inside it.
    @conversation.invocations.create!(task_id: "7", call_id: "toolu_h/t3", tool_name: "remember_note", arguments: { "key" => "k" },
      digest: "d", state: "succeeded", result: { "key" => "k" })
    get conversation_path(@conversation)
    assert_select "#tool_call_#{digest("toolu_h")}_helper ##{Invocation.dom_target("toolu_h/t2")}"
    assert_select "#tool_call_#{digest("toolu_h")}_helper ##{Invocation.dom_target("toolu_h/t3")}", count: 0
    assert_select "#tool_call_#{digest("toolu_h")}_calls ##{Invocation.dom_target("toolu_h/t3")}"
  end

  test "a report it can't read is refused" do
    [ { state: "cancelled" }, { callId: "bad id" }, { task: nil } ].each do |bad|
      post "/agent/helpers", params: payload(state: "running").merge(bad), headers: rails_bearer, as: :json
      assert_response :bad_request, bad.inspect
    end
    assert_empty @conversation.helpers
  end

  test "the agent cancels its own working helper: it stops, as at the person's Cancel, and nobody tells the agent what it did itself" do
    report state: "running"
    helper = @conversation.helpers.sole

    perform_enqueued_jobs { agent_calls "cancel_helper", helper: "toolu_h" }

    assert_equal [ "toolu_h" ], @cancels.pluck("callId")
    assert_predicate helper.reload, :cancelled?
    call = @conversation.invocations.find_by!(call_id: "toolu_a")
    assert_equal "succeeded", call.state
    assert_equal({ "cancelled" => true, "calls" => 3 }, call.result.slice("cancelled", "calls"))
    sign_in_as @alice
    show_thread_with_helper_call
    assert_select "#tool_call_#{digest("toolu_h")}_helper .helper__note", "Before the assistant cancelled it, it had run bash (2 times)."

    @conversation.submit("Any news?", request_id: "next")
    assert_no_match "helpers_cancelled", @submissions.sole["content"]

    perform_enqueued_jobs { agent_calls "cancel_helper", helper: "toolu_h", call_id: "toolu_b" }
    assert_equal "failed", @conversation.invocations.find_by!(call_id: "toolu_b").state
    assert_equal 1, @cancels.size
  end

  test "the agent reads a working helper's progress: what it is doing, and how many calls it has made" do
    report state: "running", count: 2, tools: [ { callId: "t1", name: "web_search", status: "done", output: "3 hotels" },
      { callId: "t2", name: "bash", status: "running", output: "curl …" } ]

    agent_calls "check_helper", helper: "toolu_h"

    call = @conversation.invocations.find_by!(call_id: "toolu_a")
    assert_equal "succeeded", call.state
    assert_equal({ "state" => "running", "task" => "Find three hotels near the venue.", "calls" => 2,
      "latest" => [ { "name" => "web_search", "status" => "done" }, { "name" => "bash", "status" => "running" } ] }, call.result)
    assert_empty @cancels
  end

  test "an agent can't read or cancel another conversation's helper" do
    other = create_conversation(@alice.personal_workspace.agents.create!(user: @alice, name: "Second", instructions: "Help.", model: @agent.model), durable_id: "13")
    theirs = Helper.started(other, call_id: "toolu_x", task: "Theirs.")

    perform_enqueued_jobs do
      agent_calls "cancel_helper", helper: "toolu_x"
      agent_calls "check_helper", helper: "toolu_x", call_id: "toolu_b"
    end

    assert_equal %w[ failed failed ], @conversation.invocations.order(:id).pluck(:state)
    assert_match "No helper you started", @conversation.invocations.first.error
    assert_empty @cancels
    assert_predicate theirs.reload, :running?
  end

  private
    def agent_calls(tool, call_id: "toolu_a", **arguments)
      stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes").to_return(body: { rung: true }.to_json)
      post "/agent/invocations", params: invocation_payload(@conversation, tool: tool, arguments: arguments.stringify_keys, call_id: call_id),
        headers: rails_bearer, as: :json
    end

    def payload(**data)
      { actorId: @alice.id.to_s, workspaceId: @agent.id.to_s, conversationId: "12", callId: "toolu_h",
        task: "Find three hotels near the venue.", tools: [], count: 0 }.merge(data)
    end

    # Admission knows the test's addresses; the person is found by subject.
    def sign_in_as(user, email: user == @alice ? "operator@example.com" : "member@example.com") =
      sign_in_via_ajent(subject: user.oidc_sub, email: email, name: user.name)

    def report(**data) = post("/agent/helpers", params: payload(**data), headers: rails_bearer, as: :json)

    def digest(call_id) = Digest::SHA256.hexdigest(call_id).first(16)

    def show_thread_with_helper_call
      @conversation.messages.find_or_create_by!(entry_key: "50") do |message|
        message.assign_attributes(entry_id: 50, role: "assistant", content: "",
          tool_calls: [ { "id" => "toolu_h", "name" => "subagent", "arguments" => { "task" => "Find three hotels near the venue.", "background" => true } } ])
      end
      @conversation.messages.find_or_create_by!(entry_key: "51") do |message|
        message.assign_attributes(entry_id: 51, role: "toolResult", tool_call_id: "toolu_h", tool_name: "subagent",
          content: "A helper is working on it in the background.")
      end
      get conversation_path(@conversation)
      assert_response :success
    end
end
