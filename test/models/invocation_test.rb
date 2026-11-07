require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

class InvocationTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper
  include McpTestHelper

  setup do
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
  end

  test "the digest is the sidecar's canonical JSON SHA-256 of the whole call" do
    # The same vector is asserted in agent/test/contract.test.mjs.
    conversation = Conversation.new(user_id: 1, agent_id: 2, durable_id: "3")
    digest = Invocation.digest_for(conversation, task_id: 7, call_id: "toolu_1", tool: "remember_note",
      arguments: { "key" => "greeting", "body" => "h\u00e9llo \"world\" </script>" })

    assert_equal "b5de1faf8c7e1f1e0848f2f8b54d68fbb25b2f2089dce348bfb1bc559293a978", digest
  end

  test "a replayed call returns the recorded result without running again" do
    first = receive("remember_note", "key" => "plan", "body" => "one")
    @agent.notes.sole.update!(body: "changed since")
    second = receive("remember_note", "key" => "plan", "body" => "one")

    assert_equal first, second
    assert_equal "changed since", @agent.notes.sole.body
  end

  test "arguments that break the schema fail as a result the model can read" do
    outcome = receive("remember_note", "key" => "has spaces", "body" => "x", "extra" => 1)

    assert outcome[:isError]
    assert_match "Invalid arguments", outcome[:result][:error]
    assert_empty @agent.notes
  end

  test "a tool the agent does not list is refused" do
    @agent.update!(tool_names: %w[ current_time ])
    outcome = receive("remember_note", "key" => "k", "body" => "b")

    assert_equal({ error: "remember_note is not one of this assistant's tools." }, outcome[:result])
  end

  test "an approval waits, then runs once the person allows it" do
    @agent.notes.remember("old", "x")
    assert_equal "waiting", receive("forget_note", "key" => "old")[:status]
    invocation = @conversation.invocations.sole
    assert invocation.awaiting_person?

    assert_enqueued_with(job: InvocationWakeJob, args: [ invocation ]) { invocation.approve!(by: @alice) }
    assert_equal({ status: "done", result: { forgotten: "old" }, isError: false }, receive("forget_note", "key" => "old"))
    assert_equal 0, @agent.notes.count
    assert_raises(Invocation::Conflict) { invocation.reload.approve!(by: @alice) }
  end

  test "a declined call tells the model who declined which call, and has no effect" do
    @agent.notes.remember("old", "x")
    receive("forget_note", "key" => "old")
    @conversation.invocations.sole.deny!(by: @alice)

    outcome = receive("forget_note", "key" => "old")
    assert outcome[:isError]
    assert_equal %(Alice declined forget_note {"key":"old"}.), outcome[:result][:error]
    assert_equal 1, @agent.notes.count
  end

  test "a question's answer becomes its result" do
    receive("ask_person", "question" => "Which day?", "options" => %w[ Monday Tuesday ])
    invocation = @conversation.invocations.sole

    assert_raises(ActiveRecord::RecordInvalid) { invocation.answer!(selections: %w[ Sunday ], text: "", by: @alice) }
    invocation.reload.answer!(selections: %w[ Tuesday ], text: "", by: @alice)

    assert_equal({ status: "done", result: { selections: %w[ Tuesday ] }, isError: false },
      receive("ask_person", "question" => "Which day?", "options" => %w[ Monday Tuesday ]))
  end

  test "an unanswered wait expires" do
    receive("forget_note", "key" => "old")
    travel Invocation::WAIT + 1.minute do
      outcome = receive("forget_note", "key" => "old")
      assert outcome[:isError]
      assert_equal "Nobody answered in time.", outcome[:result][:error]
    end
  end

  test "an outside tool asks first, runs once allowed, and a replay returns what was recorded" do
    create_mcp_server(@agent, tools: [ mcp_tool("publish", properties: { title: { type: "string" } }) ])
    stub_mcp_server(calls: { "publish" => ->(arguments) { { content: [ { type: "text", text: "published #{arguments['title']}" } ] } } })

    assert_equal "waiting", receive("mcp__wiki__publish", "title" => "Hello")[:status]
    assert_not_requested :post, MCP_URL
    @conversation.invocations.sole.approve!(by: @alice)

    assert_equal "waiting", receive("mcp__wiki__publish", "title" => "Hello")[:status], "the call runs in a job"
    call_outside
    done = { status: "done", result: { text: "published Hello" }, isError: false }
    assert_equal done, receive("mcp__wiki__publish", "title" => "Hello")
    assert_equal done, receive("mcp__wiki__publish", "title" => "Hello")
    assert_requested :post, MCP_URL, times: 3 # the handshake's two, and one call
  end

  test "a read-only outside tool runs at once, and its failure is a result the model reads" do
    create_mcp_server(@agent, tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ])
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "index offline" } ], isError: true } } })

    assert_equal "waiting", receive("mcp__wiki__search", {})[:status]
    call_outside
    outcome = receive("mcp__wiki__search", {})

    assert outcome[:isError]
    assert_equal({ error: "mcp__wiki__search failed: index offline" }, outcome[:result])
  end

  test "an outside call answers the sidecar at once, then a job makes it, records it and rings the doorbell" do
    create_mcp_server(@agent, tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ])
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "ok" } ] } } })

    waiting = nil
    assert_enqueued_with(job: InvocationCallJob) { waiting = receive("mcp__wiki__search", {}) }
    invocation = @conversation.invocations.sole
    assert_equal({ status: "waiting", key: invocation.wait_key, expiresAt: nil }, waiting)
    assert invocation.running?
    assert_not_requested :post, MCP_URL
    assert_not_equal "waiting", @conversation.reload.status, "an outside call is not waiting for the person"

    assert_enqueued_with(job: InvocationWakeJob, args: [ invocation ]) { perform_enqueued_jobs(only: InvocationCallJob) }
    assert invocation.reload.succeeded?
  end

  test "a replay while an outside call is running waits instead of calling again; a lost one runs again" do
    create_mcp_server(@agent, tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ])
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "ok" } ] } } })
    receive("mcp__wiki__search", {})
    call_outside
    invocation = @conversation.invocations.sole
    invocation.update_columns(state: "running", result: nil)

    assert_equal "waiting", receive("mcp__wiki__search", {})[:status]
    travel Invocation::RUN_LIMIT + 1.minute do
      assert_equal "waiting", receive("mcp__wiki__search", {})[:status]
      call_outside
      assert_equal({ status: "done", result: { text: "ok" }, isError: false }, receive("mcp__wiki__search", {}))
    end
    assert_requested :post, MCP_URL, times: 6
  end

  test "an outside tool whose server was removed is refused" do
    create_mcp_server(@agent, tools: [ mcp_tool("search") ]).destroy!

    assert_equal({ error: "mcp__wiki__search is not one of this assistant's tools." }, receive("mcp__wiki__search", {})[:result])
  end

  test "read_skill gives a skill's body through the ledger, without asking, only while the agent has skills" do
    assert_equal({ error: "read_skill is not one of this assistant's tools." }, receive("read_skill", "name" => "trip")[:result])

    @agent.skills.create!(name: "trip", description: "Plans trips.", body: "Ask where first.")
    outcome = Invocation.receive(@conversation, **read_skill_call("trip", call_id: "toolu_2")).deep_symbolize_keys
    assert_equal({ status: "done", result: { name: "trip", content: "Ask where first." }, isError: false }, outcome)
    assert @conversation.invocations.find_by!(call_id: "toolu_2").succeeded?

    missing = Invocation.receive(@conversation, **read_skill_call("other", call_id: "toolu_3")).deep_symbolize_keys
    assert missing[:isError]
    assert_equal "There is no skill called other. The skills are: trip.", missing[:result][:error]
  end

  private
    # The job that makes a claimed outside call, as the job role would.
    def call_outside = perform_enqueued_jobs(only: InvocationCallJob)

    def read_skill_call(name, call_id:)
      payload = invocation_payload(@conversation, tool: "read_skill", arguments: { "name" => name }, call_id: call_id)
      { task_id: payload[:taskId], call_id: call_id, tool: "read_skill", arguments: payload[:arguments], digest: payload[:digest] }
    end

    def receive(tool, arguments)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: payload[:callId], tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
