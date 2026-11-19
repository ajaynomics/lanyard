require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# An agent asks a question without waiting (#84): it gets the question's id
# at once and carries on. The card waits in Needs you; the person's answer
# reaches the agent later as a message naming that id, and the agent decides
# whether it still matters. It may withdraw a question it settled itself,
# and a question nobody answers expires, closing its card and telling it.
class AsyncQuestionsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  ASK = { "question" => "Which day suits the visit?", "options" => %w[ Monday Tuesday ], "wait" => false }.freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @person = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @person.agents.sole
    @conversation = create_conversation(@agent)
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12\?}).to_return(body: { status: "done", failure: nil, pendingInputs: [], queued: [] }.to_json)
    @wakes = stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes").to_return(body: { rung: true }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "asking without waiting answers at once with the question's id, and its card waits in Needs you" do
    reply = invoke("ask_person", ASK, call_id: "toolu_q")
    question = @conversation.invocations.sole

    assert_equal "done", reply["status"], "no wait: the call ends at once"
    assert_equal false, reply["isError"]
    assert_equal question.id, reply.dig("result", "question_id")
    assert question.answerable?, "the card stays open for the person"
    assert_not @conversation.held_by_card?, "it holds no step, and no steer"
    assert_includes Invocation.waiting_on_person, question
    assert_equal reply, invoke("ask_person", ASK, call_id: "toolu_q"), "a replay after a crash gets the same id"

    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_q", "name" => "ask_person" } ])
    get conversation_path(@conversation)
    assert_select ".needs-you a[href=?]", approval_path(question), text: /Which day suits the visit\?/
    assert_select "##{question.dom_target} form[action=?]", conversation_invocation_answer_path(@conversation, question)
    assert_select "##{question.dom_target}", text: /carries on meanwhile/

    get approvals_path
    assert_select "#approvals a[href=?]", approval_path(question), text: /Which day suits the visit\?/
    get approval_path(question)
    assert_select "form[action=?]", conversation_invocation_answer_path(@conversation, question)
  end

  test "the answer arrives later as a message naming the question's id" do
    question_id = invoke("ask_person", ASK, call_id: "toolu_q").dig("result", "question_id")

    perform_enqueued_jobs { post conversation_invocation_answer_path(@conversation, question_id), params: { answer: { selections: [ "Tuesday" ] } } }

    question = @conversation.invocations.find(question_id)
    assert question.succeeded?
    assert_not_requested @wakes # nothing in the sidecar waits on it
    told = @submissions.sole
    assert_equal [ "invocation:#{question_id}", "steer" ], told.values_at("requestId", "whenBusy")
    assert_match(/\A\[Question from your question #{question_id}\. /, told["content"])
    assert_match(/answered your question #{question_id}, "Which day suits the visit\?": \{"selections":\["Tuesday"\]\}/, words(told["content"]))
    assert_match(/decide whether it still matters/i, words(told["content"]))
    assert_equal({ "status" => "done", "result" => { "question_id" => question_id, "expires_at" => question.expires_at.iso8601 }.merge(note), "isError" => false },
      invoke("ask_person", ASK, call_id: "toolu_q"), "a replay still names the question, not the answer")
  end

  test "a withdrawn question's card disappears and can't be answered" do
    question_id = invoke("ask_person", ASK, call_id: "toolu_q").dig("result", "question_id")

    reply = invoke("withdraw_question", { "question_id" => question_id }, call_id: "toolu_w")
    assert_equal({ "status" => "done", "result" => { "withdrawn" => question_id }, "isError" => false }, reply)
    question = @conversation.invocations.find(question_id)
    assert_not question.answerable?
    assert_not_includes Invocation.waiting_on_person, question

    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_q", "name" => "ask_person" } ])
    get conversation_path(@conversation)
    assert_select "form[action=?]", conversation_invocation_answer_path(@conversation, question), count: 0
    assert_select ".needs-you", text: /Which day/, count: 0
    assert_select "##{question.dom_target}", text: /Withdrew the question/
    assert_select "##{question.dom_target} .ui-trace:not([data-status])", 1, "withdrawn is a normal outcome, not the error dot"
    assert_equal [ "Input", "Withdrawn" ], css_select("##{question.dom_target} .ui-code__label").map(&:text)

    perform_enqueued_jobs { post conversation_invocation_answer_path(@conversation, question), params: { answer: { text: "Monday" } } }
    assert_equal "That request has already been answered or has expired.", flash[:alert]
    assert_nil question.reload.answer
    assert_empty @submissions, "the agent withdrew it, so nothing is told back"

    again = invoke("withdraw_question", { "question_id" => question_id }, call_id: "toolu_w2")
    assert again["isError"], "a second withdrawal is refused"
  end

  test "found through find_tools, withdraw_question runs through use_tool as it does by name" do
    question_id = invoke("ask_person", ASK, call_id: "toolu_q").dig("result", "question_id")
    perform_enqueued_jobs do
      invoke("use_tool", { "name" => "withdraw_question", "arguments" => { "question_id" => question_id } }, call_id: "toolu_u")
    end

    assert_equal({ "withdrawn" => question_id }, @conversation.invocations.find_by!(call_id: "toolu_u").result)
    assert @conversation.invocations.find(question_id).withdrawn?
    assert_empty @submissions
  end

  test "an expired question can't be answered, and the agent is told" do
    question_id = invoke("ask_person", ASK.merge("expires_in_hours" => 2), call_id: "toolu_q").dig("result", "question_id")
    question = @conversation.invocations.find(question_id)
    assert_in_delta 2.hours.from_now, question.expires_at, 5.seconds

    travel 2.hours + 1.minute do
      perform_enqueued_jobs { Invocation.settle_handed_back }
      perform_enqueued_jobs { post conversation_invocation_answer_path(@conversation, question), params: { answer: { text: "Monday" } } }
    end

    assert question.reload.failed?
    assert_nil question.answer
    told = @submissions.sole
    assert_match(/Your question #{question_id}, "Which day suits the visit\?", expired: nobody answered in time\. Its card is closed/, words(told["content"]))

    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_q", "name" => "ask_person" } ])
    get conversation_path(@conversation)
    assert_select "##{question.dom_target} .ui-trace__title", "Closed the question unanswered"
    assert_select "##{question.dom_target} .ui-trace:not([data-status])", 1, "expiry is a normal outcome, not the error dot"
    assert_equal [ "Input", "Expired" ], css_select("##{question.dom_target} .ui-code__label").map(&:text)
  end

  test "a call that really failed keeps its error dot" do
    assert invoke("ask_person", ASK.except("question"), call_id: "toolu_bad")["isError"]
    failed = @conversation.invocations.sole
    assert failed.failed?

    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_bad", "name" => "ask_person" } ])
    get conversation_path(@conversation)
    assert_select "##{failed.dom_target} .ui-trace[data-status=error] .ui-trace__title", "Failed to run ask person"
    assert_equal [ "Input", "Error" ], css_select("##{failed.dom_target} .ui-code__label").map(&:text)
  end

  test "a question that waits, as before, and a helper's, still hold the step" do
    assert_equal "waiting", invoke("ask_person", ASK.except("wait"), call_id: "toolu_a")["status"]
    reply = invoke("ask_person", ASK, call_id: "toolu_h/toolu_b")
    assert reply["isError"], "a helper's result is the helper's: it waits for its answer"
    assert_match(/helper/, reply.dig("result", "error"))
    refused = invoke("ask_person", ASK.except("wait").merge("expires_in_hours" => 3), call_id: "toolu_c")
    assert refused["isError"], "a question that waits ends when the agent's wait does"
  end

  test "withdraw_question is looked up, not declared, and adds nothing to what an agent declares" do
    assert_includes @conversation.lookup_tools.map(&:tool_name), "withdraw_question"
    assert_not @conversation.declares?("withdraw_question")
    assert_not_includes Tool::Catalog::CORE, "withdraw_question"
    count = @agent.tool_count
    @agent.update!(tool_names: @agent.tool_names - [ "ask_person" ])
    assert_not_includes @agent.reload.own_tools.map(&:tool_name), "withdraw_question", "only an agent that can ask has it"
    assert_equal count - 1, @agent.tool_count, "ask_person alone: withdraw_question was never declared"
  end

  test "a question is no approval: one asked without waiting asks even where the install allows everything" do
    with_setting(:app, :approvals, "allow") do
      with_setting(:app, :approve_everything, true) do
        invoke("ask_person", ASK, call_id: "toolu_q")
        assert @conversation.invocations.sole.answerable?
      end
    end
  end

  private
    def invoke(tool, arguments, call_id:)
      post "/agent/invocations", params: invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id),
        headers: rails_bearer, as: :json
      response.parsed_body
    end

    def note = { "note" => Tool::AskPerson::ASKED_LATER }
end
