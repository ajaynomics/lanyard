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

    assert_equal({ agents: [ { address: "acme/travel", name: "Travel", description: "Books trips", network: "acme" } ] }, outcome[:result])
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

    # A crash after the send: the ledger runs the call again, which reads what
    # its dispatch recorded and sends nothing.
    invocation = @conversation.invocations.sole
    invocation.update_columns(state: "running", updated_at: 10.minutes.ago)
    invocation.advance
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_equal [ "durable-assistants:12:7:toolu_1" ], message_ids
    assert_equal "task-9", invocation.reload.result["taskId"]
    assert_equal 1, @conversation.peer_tasks.count
  end

  # The case of #86, on Concourse: it took a send and gave no answer in time;
  # the call failed saying it "may have been delivered", and the agent could
  # send the same words again, as a new message.
  test "Concourse takes a send and hangs past the wait: the call says sent, with its task, and the agent's retry sends nothing" do
    create_concourse_agent(@agent)
    stub_concourse_session
    @agent.permissions.create!(tool_name: "concourse_send", recipient: "", granted_by: @alice)
    taken = concourse_taking_then_hanging

    outcome = receive("concourse_send", "to" => "acme/travel", "text" => "Find me a flight")
    assert_equal({ taskId: "task-9", state: "TASK_STATE_SUBMITTED", network: "acme", note: "Sent. The answer will come to you as a new message." },
      outcome[:result], "sent, not failed")
    assert_equal [ "outbound", "acme/travel", "ctx-task-9" ], @conversation.peer_tasks.sole.values_at(:direction, :peer, :context_id)

    retry_outcome = receive("concourse_send", "to" => "acme/travel", "text" => "Find me a flight", call_id: "toolu_2")
    assert retry_outcome[:isError]
    assert_match(%r{This same message went to acme/travel at .* \(Concourse id task-9\), so it wasn't sent again}, retry_outcome.dig(:result, :error))
    assert_equal 1, taken.size, "sent once"

    travel(Dispatch::REPEAT_WITHIN + 1.minute) { receive("concourse_send", "to" => "acme/travel", "text" => "Find me a flight", call_id: "toolu_3") }
    assert_equal 2, taken.size, "the same words later are a new message"
  end

  test "one Concourse doesn't list yet is unknown with its key, a retry meanwhile sends nothing, and once listed the agent is told it went" do
    create_concourse_agent(@agent)
    stub_concourse_session
    told = []
    install_sidecar_settings
    stub_request(:post, %r{/v1/conversations/12/submissions}).to_return do |request|
      told << JSON.parse(request.body)
      { status: 202, body: { id: told.size, status: "queued" }.to_json }
    end
    @agent.permissions.create!(tool_name: "concourse_send", recipient: "", granted_by: @alice)
    taken = concourse_taking_then_hanging(listed_after: 3.minutes)

    outcome = receive("concourse_send", "to" => "acme/travel", "text" => "Hi")
    dispatch = @conversation.invocations.find_by!(call_id: "toolu_1").dispatch
    assert_equal({ unknown: "acme/travel", network: "acme", key: dispatch.key, note: Tool::ConcourseSend::UNCONFIRMED }, outcome[:result])
    assert dispatch.checking?
    assert_empty @conversation.peer_tasks

    retry_outcome = receive("concourse_send", "to" => "acme/travel", "text" => "Hi", call_id: "toolu_2")
    assert_match(/may have gone and is still being checked \(key #{dispatch.key}\), so it wasn't sent again/, retry_outcome.dig(:result, :error))

    travel(Dispatch::CHECK_AFTER + 1.second) { perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current) }
    assert dispatch.reload.checking?, "not listed yet: checked again later"
    travel(10.minutes) do
      perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current)
      perform_enqueued_jobs(only: DispatchReportJob)
    end
    assert_equal [ "sent", "task-9" ], [ dispatch.reload.state, dispatch.provider_id ]
    assert_match(/concourse_send .*Hi.*went after all: its id is task-9\. Don't send it again/, told.sole["content"])
    assert_equal "task-9", @conversation.peer_tasks.sole.task_id, "linked, so its answer reaches the agent"
    assert_equal 1, taken.size, "sent once"
  ensure
    remove_sidecar_settings
  end

  test "a call whose send was recorded never sends again, even if its job runs twice: it asks for the receipt instead" do
    create_concourse_agent(@agent)
    stub_concourse_session
    @agent.permissions.create!(tool_name: "concourse_send", recipient: "", granted_by: @alice)
    taken = concourse_taking_then_hanging(listed_after: 1.day)
    first = receive("concourse_send", "to" => "acme/travel", "text" => "Hi")
    assert first[:result][:unknown]

    invocation = @conversation.invocations.sole
    invocation.update_columns(state: "running", result: nil)
    travel(1.day + 1.minute) { invocation.call_outside }
    assert_equal 1, taken.size
    assert_equal "task-9", invocation.reload.result.dig("taskId"), "found by its receipt, not sent again"
  end

  test "no receipt an hour on is never called not sent: it stays unknown, and a retry is refused until a person says" do
    create_concourse_agent(@agent)
    stub_concourse_session
    @agent.permissions.create!(tool_name: "concourse_send", recipient: "", granted_by: @alice)
    taken = concourse_taking_then_hanging(listed_after: 1.day)
    receive("concourse_send", "to" => "acme/travel", "text" => "Hi")
    dispatch = @conversation.invocations.sole.dispatch

    travel(Dispatch::NOT_LISTED_AFTER + 1.minute) { dispatch.check }
    assert dispatch.reload.unknown?
    retry_outcome = travel(Dispatch::NOT_LISTED_AFTER + 2.minutes) { receive("concourse_send", "to" => "acme/travel", "text" => "Hi", call_id: "toolu_2") }
    assert_match(/whether it did is still unknown \(key #{dispatch.key}\), so it wasn't sent again/, retry_outcome.dig(:result, :error))
    assert_equal 1, taken.size
  end

  test "Concourse refusing a send outright is not sent, and may be sent again" do
    create_concourse_agent(@agent)
    stub_concourse_session
    @agent.permissions.create!(tool_name: "concourse_send", recipient: "", granted_by: @alice)
    stub_request(:post, "#{ORIGIN}/a2a/acme/acme/travel").to_return(status: 403, body: { reason: "not_a_member" }.to_json)

    outcome = receive("concourse_send", "to" => "acme/travel", "text" => "Hi")
    assert outcome[:isError]
    assert @conversation.invocations.sole.dispatch.not_sent?
    assert receive("concourse_send", "to" => "acme/travel", "text" => "Hi", call_id: "toolu_2")[:isError], "asked again, and refused again"
    assert_requested :post, "#{ORIGIN}/a2a/acme/acme/travel", times: 2
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

  # The live case (#238): the job role was minutes behind, a reply's job began
  # 8 minutes after it was queued, and by then the call had been failed as
  # lost, so the reply was never sent and the peer's task stayed open.
  test "a reply whose job is still queued 8 minutes on is not lost: it waits, and goes once the job runs" do
    create_concourse_agent(@agent)
    stub_concourse_session
    @conversation.peer_tasks.create!(task_id: "task-1", peer: "acme/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED")
    reply = stub_request(:patch, "#{ORIGIN}/tasks/task-1").to_return(body: concourse_task(state: "TASK_STATE_COMPLETED").to_json)
    arguments = { "task_id" => "task-1", "state" => "completed", "text" => "Done." }
    payload = invocation_payload(@conversation, tool: "concourse_reply", arguments: arguments, call_id: "toolu_1")
    ask = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: "toolu_1", tool: "concourse_reply",
      arguments: arguments, digest: payload[:digest]).deep_symbolize_keys }

    assert_equal "waiting", ask.call[:status]
    travel 8.minutes do
      assert_equal "waiting", ask.call[:status], "its job has not begun the call, so nothing has happened yet"
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_equal "TASK_STATE_COMPLETED", ask.call.dig(:result, :state)
    end
    assert_requested reply, times: 1
    assert_equal "TASK_STATE_COMPLETED", @conversation.peer_tasks.sole.state
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

  test "with two networks a new send must name one, and is refused before anyone is asked; named, it goes and is tagged there" do
    first = create_concourse_agent(@agent)
    second = create_second_network(@agent)
    stub_concourse_session
    sent = stub_request(:post, %r{\A#{ORIGIN}/a2a/}).with(headers: { "Authorization" => "Bearer #{SECOND_TOKEN}" })
      .to_return(body: { jsonrpc: "2.0", id: "x", result: { task: concourse_task(id: "task-9", context_id: "ctx-9") } }.to_json)

    refused = receive("concourse_send", "to" => "example/travel", "text" => "Hi")
    assert_equal "Assistant is on more than one network. Name the network: acme or example.", refused.dig(:result, :error)
    assert_equal "failed", @conversation.invocations.sole.state, "nobody is asked to allow it"
    refused = receive("concourse_send", "to" => "example/travel", "text" => "Hi", "network" => "elsewhere", call_id: "toolu_2")
    assert_equal "Assistant is not on network elsewhere. Its networks: acme or example.", refused.dig(:result, :error)

    receive("concourse_send", "to" => "example/travel", "text" => "Hi", "network" => "example", call_id: "toolu_3")
    @conversation.invocations.find_by(call_id: "toolu_3").approve!(by: @alice)
    outcome = receive("concourse_send", "to" => "example/travel", "text" => "Hi", "network" => "example", call_id: "toolu_3")

    assert_equal "example", outcome.dig(:result, :network)
    assert_requested sent, times: 1
    assert_requested :post, "#{ORIGIN}/a2a/example/example/travel"
    assert_equal second, @conversation.peer_tasks.sole.concourse_agent
    assert_not_equal first, @conversation.peer_tasks.sole.channel
  end

  test "a reply, a read and a follow-up go on the network the task came or went on, whatever is named" do
    create_concourse_agent(@agent)
    second = create_second_network(@agent)
    stub_concourse_session
    @conversation.peer_tasks.create!(task_id: "task-1", peer: "example/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED", concourse_agent: second)
    @conversation.peer_tasks.create!(task_id: "task-9", peer: "example/travel", direction: "outbound", state: "TASK_STATE_INPUT_REQUIRED", concourse_agent: second)
    on_second = { "Authorization" => "Bearer #{SECOND_TOKEN}" }
    reply = stub_request(:patch, "#{ORIGIN}/tasks/task-1").with(headers: on_second).to_return(body: concourse_task(state: "TASK_STATE_COMPLETED").to_json)
    read = stub_request(:get, "#{ORIGIN}/api/tasks/task-9").with(headers: on_second).to_return(body: concourse_task(id: "task-9").to_json)
    follow = stub_request(:post, "#{ORIGIN}/a2a/example/example/travel").with(headers: on_second)
      .to_return(body: { jsonrpc: "2.0", id: "x", result: { task: concourse_task(id: "task-9", context_id: "ctx-9") } }.to_json)

    assert_equal "TASK_STATE_COMPLETED", receive("concourse_reply", "task_id" => "task-1", "state" => "completed", "text" => "Done.").dig(:result, :state)
    assert_equal "task-9", receive("concourse_get", "task_id" => "task-9", call_id: "toolu_2").dig(:result, :taskId)
    arguments = { "to" => "example/travel", "text" => "Friday.", "task_id" => "task-9", "network" => "acme" }
    receive("concourse_send", arguments.merge(call_id: "toolu_3"))
    @conversation.invocations.find_by(call_id: "toolu_3").approve!(by: @alice)
    receive("concourse_send", arguments.merge(call_id: "toolu_3"))

    assert_requested reply, times: 1
    assert_requested read, times: 1
    assert_requested follow, times: 1
  end

  test "a task whose network the agent has left can no longer be acted on" do
    create_concourse_agent(@agent)
    second = create_second_network(@agent)
    @conversation.peer_tasks.create!(task_id: "task-1", peer: "example/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED", concourse_agent: second)
    second.update!(status: "declined")

    refused = receive("concourse_reply", "task_id" => "task-1", "state" => "completed", "text" => "Done.")
    assert_equal "Task task-1 came on network example, where Assistant is not connected now.", refused.dig(:result, :error)

    second.destroy!
    refused = receive("concourse_reply", "task_id" => "task-1", "state" => "completed", "text" => "Done.", call_id: "toolu_2")
    assert_equal "Task task-1 came on a network Assistant has left.", refused.dig(:result, :error)
  end

  test "find searches every network, each answer labelled; named, only that one" do
    create_concourse_agent(@agent)
    create_second_network(@agent)
    stub_concourse_session
    stub_concourse(:get, "agents", { agents: [ { handle: "acme/travel", name: "Travel" } ] })
    stub_request(:get, "#{ORIGIN}/agents").with(headers: { "Authorization" => "Bearer #{SECOND_TOKEN}" })
      .to_return(body: { agents: [ { handle: "example/books", name: "Books" } ] }.to_json)

    assert_equal [ %w[ acme/travel acme ], %w[ example/books example ] ], receive("concourse_find", {}).dig(:result, :agents).map { it.values_at(:address, :network) }
    assert_equal [ "example/books" ], receive("concourse_find", { "network" => "example", call_id: "toolu_2" }).dig(:result, :agents).pluck(:address)
  end

  test "on two networks the agent is told which, so its definition changes; on one, its words are as before" do
    create_concourse_agent(@agent)
    one = @agent.reload.conversation.definition
    assert_not_includes one[:instructions], "On Concourse"

    create_second_network(@agent)
    two = @agent.reload.conversation.definition
    assert_includes two[:instructions], "On Concourse you are in these networks, so name one when you send a new task: acme as acme/assistant and example as example/assistant."
    assert_not_equal one[:digest], two[:digest]
    assert_equal two[:tools], one[:tools], "the tools stay the same; the network is an argument they always had"

    @agent.concourse_agents.last.update!(status: "awaiting_approval")
    assert_equal one[:digest], @agent.reload.conversation.definition[:digest], "only networks it can send on are listed"
  end

  # Two bridges, acme and example, outside the workspace's home network
  # (docs/design/workspaces.md, 3): a task from acme is answered only on acme,
  # and its words reach example only in a send a person allows, each time,
  # whatever "Always" or the install says, and the ledger keeps who allowed it.
  test "with two bridges, a task stays on its network, and a send onto a bridge asks a person every time and is recorded" do
    @agent.workspace.update!(concourse_home: "home")
    first = create_concourse_agent(@agent, bridge_approved_by: @alice, bridge_approved_at: Time.current)
    second = create_second_network(@agent, bridge_approved_by: @alice, bridge_approved_at: Time.current)
    assert [ first, second ].all?(&:bridge?)
    stub_concourse_session
    @conversation.peer_tasks.create!(task_id: "task-1", peer: "acme/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED", concourse_agent: first)
    on_first = stub_request(:patch, "#{ORIGIN}/tasks/task-1").with(headers: { "Authorization" => "Bearer #{ACCESS_TOKEN}" })
      .to_return(body: concourse_task(state: "TASK_STATE_COMPLETED").to_json)
    to_second = stub_request(:post, "#{ORIGIN}/a2a/example/example/travel").with(headers: { "Authorization" => "Bearer #{SECOND_TOKEN}" })
      .to_return(body: { jsonrpc: "2.0", id: "x", result: { task: concourse_task(id: "task-9", context_id: "ctx-9") } }.to_json)
    @agent.permissions.create!(tool_name: "concourse_send", recipient: "", granted_by: @alice)

    receive("concourse_reply", "task_id" => "task-1", "state" => "completed", "text" => "Done.")
    assert_requested on_first, times: 1

    forwarded = { "to" => "example/travel", "text" => "acme/friend asked for this.", "network" => "example", call_id: "toolu_2" }
    with_setting(:app, :approve_everything, true) do
      assert_equal "waiting", receive("concourse_send", forwarded.dup)[:status], "Always and approve-everything do not cross a bridge"
    end
    send = @conversation.invocations.find_by!(call_id: "toolu_2")
    assert send.awaiting_person?
    assert_empty send.always_choices, "nobody may allow a bridge Always"
    assert_not_requested to_second

    send.approve!(by: @alice)
    assert_equal "task-9", receive("concourse_send", forwarded.dup).dig(:result, :taskId)
    assert_requested to_second, times: 1
    assert_equal [ "approve", @alice ], send.reload.approval.values_at(:decision, :decided_by), "the ledger keeps who allowed the crossing"
    assert_equal second, @conversation.peer_tasks.find_by!(task_id: "task-9").concourse_agent
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
