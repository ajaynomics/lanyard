require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/concourse_test_helper"

class ConcourseSendGuardTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ConcourseTestHelper
  include ActiveJob::TestHelper

  TEXT = "Check the timetable.\nDo not book anything.  ".freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the signed-in person's agent
    @conversation = create_conversation(@agent, durable_id: "12")
    @channel = create_concourse_agent(@agent)
    stub_concourse_session
  end

  teardown { remove_sidecar_settings }

  %w[ new continuation reply ].each do |kind|
    test "#{kind} asks once under workspace auto-approval and remembered approval" do
      @agent.workspace.update!(approval_policy: "everything")
      @agent.update!(asks_every_concourse_send: true)
      tool, args, wire = prepare_send(kind)
      [ "", "acme/travel" ].each do |recipient|
        @agent.permissions.create!(tool_name: tool, recipient: recipient, granted_by: @agent.user)
      end

      denied = invoke(tool, args, "deny")
      assert denied.awaiting_person?
      assert_not_requested wire
      answer(denied, "deny")
      perform_enqueued_jobs(only: InvocationCallJob) { invoke(tool, args, "deny") }
      assert denied.reload.denied?
      assert_not_requested wire

      @agent.workspace.update!(approval_policy: nil)
      approved = invoke(tool, args, "script_1/#{kind}")
      assert approved.awaiting_person?
      assert_not_requested wire
      html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: approved }))
      assert_equal [ "Allow once", "Deny" ], html.css(".ui-card__actions button").map { it.text.strip }
      assert_includes html.css(".ui-fields__text").map(&:text), TEXT
      assert_includes html.css(".ui-fields__text").map(&:text), "acme/travel"
      assert_includes html.css(".ui-fields__text").map(&:text), "acme"
      answer(approved, "approve", always: "agent")
      assert_response :bad_request
      assert approved.reload.awaiting_person?
      assert_not_requested wire

      answer(approved, "approve")
      assert_response :redirect
      assert_not_requested wire
      perform_enqueued_jobs(only: InvocationCallJob) do
        invoke(tool, args, "script_1/#{kind}")
        invoke(tool, args, "script_1/#{kind}")
      end
      assert approved.reload.succeeded?
      assert_requested wire, times: 1
    end
  end

  test "off by default preserves an unasked reply and the normal send rule" do
    assert_not @agent.asks_every_concourse_send?
    tool, args, wire = prepare_send("reply")
    perform_enqueued_jobs(only: InvocationCallJob) { assert invoke(tool, args, "reply").reload.succeeded? }
    assert_requested wire, times: 1

    tool, args, wire = prepare_send("new")
    assert invoke(tool, args, "send").awaiting_person?
    assert_not_requested wire
    @agent.workspace.update!(approval_policy: "everything")
    perform_enqueued_jobs(only: InvocationCallJob) { assert invoke(tool, args, "allowed").reload.succeeded? }
    assert_requested wire, times: 1
  end

  test "a checked reply cannot send to a different linked peer after approval" do
    @agent.update!(asks_every_concourse_send: true)
    tool, args, wire = prepare_send("reply")
    invocation = invoke(tool, args, "reply")
    assert invocation.awaiting_person?
    answer(invocation, "approve")
    @conversation.peer_tasks.inbound.sole.update!(peer: "acme/other")
    perform_enqueued_jobs(only: InvocationCallJob) { invoke(tool, args, "reply") }
    assert invocation.reload.failed?
    assert_match "recipient or network changed", invocation.error
    assert_not_requested wire
  end

  test "enabling the switch does not hold ordinary inbound delivery" do
    @agent.update!(asks_every_concourse_send: true)
    submissions = stub_request(:post, %r{/v1/conversations/12/submissions\z}).to_return(status: 202,
      body: { id: 1, status: "queued" }.to_json)
    @channel.send(:receive, concourse_task(caller: "acme/travel"))
    assert_requested submissions, times: 1
    assert_equal "acme/travel", @conversation.peer_tasks.inbound.sole.peer
    assert_empty @conversation.invocations
  end

  private
    def prepare_send(kind)
      args = { "text" => TEXT }
      if kind == "reply"
        link_task("inbound", "task-in")
        wire = stub_request(:patch, "#{ORIGIN}/tasks/task-in")
          .with(body: { state: "TASK_STATE_INPUT_REQUIRED", message: { parts: [ { text: TEXT } ] } }.to_json)
          .to_return(body: concourse_task(id: "task-in", state: "TASK_STATE_INPUT_REQUIRED").to_json)
        [ "concourse_reply", args.merge("task_id" => "task-in", "state" => "input_required"), wire ]
      else
        task_id = "task-out" if kind == "continuation"
        link_task("outbound", task_id) if task_id
        wire = stub_request(:post, "#{ORIGIN}/a2a/acme/acme/travel").with { |request|
          message = JSON.parse(request.body).dig("params", "message")
          message["taskId"] == task_id && message.dig("parts", 0, "text") == TEXT
        }.to_return(body: { jsonrpc: "2.0", id: "x", result: { task: concourse_task(id: task_id || "task-made") } }.to_json)
        [ "concourse_send", args.merge("to" => "acme/travel", "task_id" => task_id).compact, wire ]
      end
    end

    def link_task(direction, task_id)
      @conversation.peer_tasks.create!(task_id: task_id, context_id: "ctx-1", peer: "acme/travel", direction: direction,
        state: "TASK_STATE_SUBMITTED", concourse_agent: @channel)
    end

    def invoke(tool, arguments, call_id)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      post "/agent/invocations", params: payload, headers: rails_bearer, as: :json
      assert_response :ok
      @conversation.invocations.find_by!(call_id: call_id)
    end

    def answer(invocation, decision, **options)
      post conversation_invocation_approval_path(@conversation, invocation), params: { decision: decision, **options }
    end
end
