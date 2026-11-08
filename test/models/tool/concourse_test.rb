require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

class Tool::ConcourseTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ConcourseTestHelper
  include ActiveJob::TestHelper

  setup do
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent, durable_id: "12")
  end

  test "an agent has the concourse_ tools only when it is on Concourse" do
    assert_not_includes @agent.conversation.definition[:tools].pluck(:name), "concourse_send"

    create_concourse_agent(@agent)
    tools = @agent.reload.conversation.tools

    assert_equal %w[ concourse_find concourse_get concourse_send concourse_reply ], tools.map(&:tool_name).grep(/concourse/)
    assert_equal :approval, @agent.conversation.tool("concourse_send").asks
    assert_nil @agent.conversation.tool("concourse_reply").asks
    assert_nil @agent.conversation.tool("concourse_find").asks
    assert(tools.grep(/Concourse/).all? { it.effect == :external })
  end

  test "find lists the organization's agents" do
    create_concourse_agent(@agent)
    stub_concourse_session
    stub_request(:get, "#{ORIGIN}/agents?query=travel")
      .to_return(body: { agents: [ { handle: "acme/travel", name: "Travel", description: "Books trips" } ] }.to_json)

    outcome = receive("concourse_find", "query" => "travel")

    assert_equal({ agents: [ { address: "acme/travel", name: "Travel", description: "Books trips" } ] }, outcome[:result])
  end

  test "a send asks first, then goes once under a messageId named by the call, and links the task" do
    create_concourse_agent(@agent)
    stub_concourse_session
    message_ids = []
    stub_request(:post, "#{ORIGIN}/a2a/acme/acme/travel")
      .with { |request| message_ids << JSON.parse(request.body).dig("params", "message", "messageId") }
      .to_return(body: { jsonrpc: "2.0", id: "x", result: { task: concourse_task(id: "task-9", context_id: "ctx-9") } }.to_json)

    assert_equal "waiting", receive("concourse_send", "to" => "acme/travel", "text" => "Find me a flight")[:status]
    assert_empty message_ids
    @conversation.invocations.sole.approve!(by: @alice)

    outcome = receive("concourse_send", "to" => "acme/travel", "text" => "Find me a flight")
    assert_equal "task-9", outcome.dig(:result, :taskId)
    assert_equal [ "durable-assistants:12:7:toolu_1" ], message_ids
    peer_task = @conversation.peer_tasks.sole
    assert_equal [ "outbound", "acme/travel", "ctx-9" ], [ peer_task.direction, peer_task.peer, peer_task.context_id ]

    # A crash between the send and its record: the ledger runs the call again, as the same message.
    invocation = @conversation.invocations.sole
    invocation.update_columns(state: "running", updated_at: 10.minutes.ago)
    invocation.advance
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_equal [ "durable-assistants:12:7:toolu_1" ] * 2, message_ids
    assert_equal 1, @conversation.peer_tasks.count
  end

  test "a send that got no answer tells the model it may have been delivered" do
    create_concourse_agent(@agent)
    stub_concourse_session
    stub_request(:post, "#{ORIGIN}/a2a/acme/acme/travel").to_timeout
    receive("concourse_send", "to" => "acme/travel", "text" => "Hi")
    @conversation.invocations.sole.approve!(by: @alice)

    outcome = receive("concourse_send", "to" => "acme/travel", "text" => "Hi")

    assert outcome[:isError]
    assert_match(/may have been delivered/, outcome.dig(:result, :error))
  end

  test "a reply needs a task a peer sent this agent, and an explicit state" do
    create_concourse_agent(@agent)
    stub_concourse_session
    reply = stub_request(:patch, "#{ORIGIN}/tasks/task-1")
      .with(body: { state: "TASK_STATE_INPUT_REQUIRED", message: { parts: [ { text: "Which day?" } ] } }.to_json)
      .to_return(body: concourse_task(state: "TASK_STATE_INPUT_REQUIRED").to_json)

    refused = receive("concourse_reply", "task_id" => "task-1", "state" => "input_required", "text" => "Which day?")
    assert_match(/not one a peer sent this agent/, refused.dig(:result, :error))
    assert_not_requested reply

    other = create_conversation(@agent, durable_id: "13")
    other.peer_tasks.create!(task_id: "task-1", peer: "acme/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED")
    @conversation.peer_tasks.create!(task_id: "task-1", peer: "acme/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED")
    outcome = receive("concourse_reply", "task_id" => "task-1", "state" => "input_required", "text" => "Which day?", call_id: "toolu_2")

    assert_equal({ taskId: "task-1", state: "TASK_STATE_INPUT_REQUIRED" }, outcome[:result])
    assert_equal "TASK_STATE_INPUT_REQUIRED", @conversation.peer_tasks.sole.state
    assert_invalid = receive("concourse_reply", "task_id" => "task-1", "state" => "done", "text" => "x", call_id: "toolu_3")
    assert_match(/Invalid arguments/, assert_invalid.dig(:result, :error))
  end

  test "get reads only a task linked to this conversation, marked as peer content" do
    create_concourse_agent(@agent)
    stub_concourse_session
    @conversation.peer_tasks.create!(task_id: "task-9", peer: "acme/travel", direction: "outbound", state: "TASK_STATE_SUBMITTED")
    stub_concourse(:get, "api/tasks/task-9", concourse_task(id: "task-9", state: "TASK_STATE_COMPLETED", status_message: [ "a-1", "Booked." ]))

    outcome = receive("concourse_get", "task_id" => "task-9")
    assert_equal "Booked.", outcome.dig(:result, :answer)
    assert outcome.dig(:result, :untrustedPeerContent)
    assert_equal "TASK_STATE_COMPLETED", @conversation.peer_tasks.sole.state

    assert receive("concourse_get", "task_id" => "task-other", call_id: "toolu_2")[:isError]
  end

  private
    # As the sidecar does: an outside call answers "waiting" while its job makes
    # the call, then the sidecar asks again and gets the result.
    def receive(tool, arguments)
      call_id = arguments.delete(:call_id) || "toolu_1"
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      ask = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys }
      outcome = ask.call
      return outcome unless @conversation.invocations.find_by(call_id: call_id)&.running?
      perform_enqueued_jobs(only: InvocationCallJob)
      ask.call
    end
end
