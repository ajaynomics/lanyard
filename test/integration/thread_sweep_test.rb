require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ThreadSweepTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @person = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@person.agents.sole)
    @other = @person.start_agent("Other thread").conversation
    @submission = stub_request(:post, %r{#{SIDECAR}/v1/conversations/[^/]+/submissions}).to_return(status: 202, body: { id: 1 }.to_json)
    @wake = stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes").to_return(body: { rung: true }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "review reads one current card and resumes from the same thread's records" do
    second = question(@conversation, "Second decision", 2.minutes.ago)
    first = question(@conversation, "First decision", 5.minutes.ago)
    question(@conversation, "Already answered", 8.minutes.ago, state: "succeeded")
    question(@conversation, "Expired decision", 9.minutes.ago, expires_at: 1.minute.ago)
    question(@other, "In another thread", 1.hour.ago)

    assert_no_enqueued_jobs do
      assert_no_changes -> { @conversation.reload.attributes } do
        assert_no_changes -> { @conversation.invocations.reload.map(&:attributes) } do
          get sweep_path
        end
      end
    end
    assert_response :success
    assert_select "#conversation_sweep a[href=?]", approval_path(first), text: "Review on its card"
    assert_select "#conversation_sweep", text: /First decision/
    assert_select "#conversation_sweep", text: /Second decision|Already answered|Expired decision|In another thread/, count: 0
    assert_select "#conversation_sweep form", count: 0
    assert_not_requested @submission
    assert_not_requested @wake

    post conversation_invocation_answer_path(@conversation, first), params: { answer: { text: "The north room" } }
    assert_response :see_other
    assert_predicate first.reload, :approved?
    assert_equal "The north room", first.answer.text

    get sweep_path
    assert_response :success
    assert_select "#conversation_sweep a[href=?]", approval_path(second)
    assert_select "#conversation_sweep", text: /First decision/, count: 0
    assert_not_requested @submission
  end

  test "a raw slash command cannot submit to the agent or call a sweep write" do
    post conversation_submissions_path(@conversation), params: { content: "/sweep", request_id: "sweep-1" }
    assert_redirected_to sweep_path
    post conversation_submissions_path(@conversation), params: { content: "/sweep send anything", request_id: "sweep-2" }, as: :json
    assert_response :unprocessable_entity
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path(sweep_path, method: :post) }
    assert_not_requested @submission
    assert_empty @conversation.invocations
  end

  test "an empty review cannot offer an action" do
    get sweep_path
    assert_response :success
    assert_select "#conversation_sweep", text: /Nothing is waiting in this thread/
    assert_select "#conversation_sweep a", count: 1
    assert_not_requested @submission
    assert_not_requested @wake
  end

  test "a conversation outside the person's workspaces returns nothing" do
    outsider = create_user(name: "Other owner").agents.sole.conversation
    question(outsider, "Private decision", 1.minute.ago)
    get "#{conversation_path(outsider)}/sweep"
    assert_response :not_found
    assert_select "#conversation_sweep", count: 0
  end

  private
    def sweep_path = "#{conversation_path(@conversation)}/sweep"

    def question(conversation, title, timestamp, **attributes)
      conversation.invocations.create!({ task_id: "sweep-test", call_id: title.parameterize, tool_name: "ask_person",
        arguments: { "question" => title }, digest: title.parameterize, state: "awaiting_person", expires_at: 1.day.from_now,
        created_at: timestamp }.merge(attributes))
    end
end
