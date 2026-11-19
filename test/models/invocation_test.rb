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
    conversation = Conversation.new(agent: Agent.new(id: 2, user_id: 1), durable_id: "3")
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

    assert_equal({ error: "remember_note is not one of this agent's tools." }, outcome[:result])
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

  test "answering one of two cards leaves the thread waiting on the other, and the bar above the box names it" do
    @agent.notes.remember("old", "x")
    @agent.notes.remember("older", "y")
    first, second = %w[ toolu_h1/toolu_a toolu_h2/toolu_b ].map.with_index do |call_id, task|
      payload = invocation_payload(@conversation, tool: "forget_note", arguments: { "key" => %w[ old older ][task] }, task_id: task, call_id: call_id)
      Invocation.receive(@conversation, task_id: task, call_id: call_id, tool: "forget_note", arguments: payload[:arguments], digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: call_id)
    end
    assert_equal "waiting", @conversation.reload.status

    streams = capture_turbo_stream_broadcasts(@conversation) { first.approve!(by: @alice) }
    assert_equal "waiting", @conversation.reload.status
    bar = streams.find { it["target"] == "needs_you_conversation_#{@conversation.id}" }
    assert_includes bar.to_html, %(href="/approvals/#{second.id}")

    second.deny!(by: @alice)
    assert_equal "idle", @conversation.reload.status, "a helper's card answered says nothing of the agent's run, which never started"
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

  # A worker killed after its job began the call, perhaps after it happened,
  # before its result was saved: running it again could send a second email,
  # text or post. RUN_LIMIT counts from when the job began the call, no longer
  # from when it was queued (#238).
  test "a replay while an outside call is running waits; one its job began and then went silent past RUN_LIMIT fails as unknown and is never made again" do
    create_mcp_server(@agent, tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ])
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "ok" } ] } } })
    receive("mcp__wiki__search", {})
    invocation = @conversation.invocations.sole
    assert invocation.running?
    travel(2.minutes) { invocation.update_columns(started_at: Time.current) } # its job began, and its worker was killed
    clear_enqueued_jobs

    travel 2.minutes + Invocation::RUN_LIMIT - 1.minute do
      assert_no_enqueued_jobs(only: InvocationCallJob) { assert_equal "waiting", receive("mcp__wiki__search", {})[:status] }
    end
    travel 2.minutes + Invocation::RUN_LIMIT + 1.minute do
      lost = { status: "done", result: { error: "mcp__wiki__search: #{Invocation::LOST}" }, isError: true }
      assert_no_enqueued_jobs(only: InvocationCallJob) { assert_equal lost, receive("mcp__wiki__search", {}) }
      assert_equal lost, receive("mcp__wiki__search", {})
      InvocationCallJob.perform_now(invocation)
    end
    assert invocation.reload.failed?
    assert_not_requested :post, MCP_URL
  end

  # Until its job begins the call nothing has gone, so a busy job role is no
  # reason to give it up; it is given up only past QUEUE_LIMIT, saying so.
  test "a call whose job never began waits past RUN_LIMIT, then ends past QUEUE_LIMIT saying it was never made, and never is" do
    create_mcp_server(@agent, tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ])
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "ok" } ] } } })
    receive("mcp__wiki__search", {})
    WebMock::RequestRegistry.instance.reset!

    travel Invocation::RUN_LIMIT + 1.minute do
      assert_no_enqueued_jobs(only: InvocationCallJob) { assert_equal "waiting", receive("mcp__wiki__search", {})[:status] }
    end
    travel Invocation::QUEUE_LIMIT + 1.minute do
      never = { status: "done", result: { error: "mcp__wiki__search: #{Invocation::NEVER_STARTED}" }, isError: true }
      assert_equal never, receive("mcp__wiki__search", {})
      call_outside
      assert_equal never, receive("mcp__wiki__search", {})
    end
    assert_not_requested :post, MCP_URL
  end

  # A call claimed by code from before claimed_at, still running across the
  # deploy, may have begun: it keeps the rule it had.
  test "a call claimed before claimed_at was recorded is judged as begun: lost past RUN_LIMIT" do
    create_mcp_server(@agent, tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ])
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "ok" } ] } } })
    receive("mcp__wiki__search", {})
    @conversation.invocations.sole.update_columns(claimed_at: nil)

    travel Invocation::RUN_LIMIT + 1.minute do
      assert_equal "mcp__wiki__search: #{Invocation::LOST}", receive("mcp__wiki__search", {}).dig(:result, :error)
    end
  end

  test "an outside tool whose server was removed is refused" do
    create_mcp_server(@agent, tools: [ mcp_tool("search") ]).destroy!

    assert_equal({ error: "mcp__wiki__search is not one of this agent's tools." }, receive("mcp__wiki__search", {})[:result])
  end

  test "read_skill gives a skill's body through the ledger, without asking, only while the agent has skills" do
    assert_equal({ error: "read_skill is not one of this agent's tools." }, receive("read_skill", "name" => "trip")[:result])

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
