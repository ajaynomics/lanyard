require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# What each model call used, recorded once as the sidecar reports it, against
# the workspace and agent that made it and the workspace whose account it is
# billed to (docs/billing.md).
class ModelUsageTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @a = Workspace.create!(name: "Acorn")
    @a.memberships.create!(user: @alice, role: "owner")
    @b = Workspace.create!(name: "Birch")
    @b.memberships.create!(user: @alice, role: "owner")
    @agent = @alice.start_agent("Ada", workspace: @a)
    @conversation = create_conversation(@agent, durable_id: "a-1")
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/a-1/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "an agent in A that bills to B's account has its usage attributed to A and paid by B" do
    @a.update!(payer: @b)

    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 100, output: 20, cacheRead: 900, cost: 0.05) })

    usage = ModelUsage.sole
    assert_equal [ @a, @agent, @conversation, @b ], [ usage.workspace, usage.agent, usage.conversation, usage.payer ]
    assert_equal [ "anthropic/claude-opus-5-5", nil ], [ usage.model, usage.tool ]
    assert_equal [ 100, 20, 900, 0, 1020 ], [ usage.input, usage.output, usage.cache_read, usage.cache_write, usage.total_tokens ]
    assert_in_delta 0.05, usage.cost
    assert_equal "Ada", usage.agent_name

    @a.update!(payer: nil)
    @agent.destroy!
    assert_equal [ @a.id, nil, nil, @b.id, "Ada" ], usage.reload.values_at(:workspace_id, :agent_id, :conversation_id, :payer_id, :agent_name),
      "who made it and who paid is kept as it was, whatever changes after"
  end

  test "a call without a payer configured is paid by the install, as before" do
    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 10, output: 2) })

    assert_equal [ [ @a.id, nil ] ], ModelUsage.pluck(:workspace_id, :payer_id)
  end

  test "a workspace that pays for itself is its own payer" do
    @a.update!(payer: @a)
    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 10, output: 2) })

    assert_equal @a, ModelUsage.sole.payer
  end

  test "each run records what it added to each model and tool since the last, and a repeated report nothing" do
    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 100, output: 20) })
    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 100, output: 20) })
    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 150, output: 30), "anthropic/claude-haiku-5-5" => counts(input: 7, output: 1) },
      tools: { "web_search" => counts(input: 40, output: 5, cost: 0.01) })

    rows = ModelUsage.order(:id).map { [ it.model, it.tool, it.input, it.output ] }
    assert_equal [ [ "anthropic/claude-opus-5-5", nil, 100, 20 ], [ "anthropic/claude-opus-5-5", nil, 50, 10 ],
      [ "anthropic/claude-haiku-5-5", nil, 7, 1 ], [ nil, "web_search", 40, 5 ] ], rows
  end

  test "a thread from before metering is counted from its next report, never its whole history at once" do
    @conversation.update!(usage: Usage.from(counts(input: 5_000, output: 900)))

    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 5_000, output: 900) })
    assert_empty ModelUsage.all, "what it used before is not this month's"

    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 5_300, output: 960) })
    assert_equal [ [ 300, 60 ] ], ModelUsage.pluck(:input, :output)
  end

  test "a page load's look at the thread records what the last frame missed" do
    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 100, output: 20) })
    usage = counts(input: 130, output: 25).merge("models" => { "anthropic/claude-opus-5-5" => counts(input: 130, output: 25) }, "tools" => {})
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/a-1\?}).to_return(body: { status: "idle", usage: usage }.to_json)

    @conversation.refresh_status!

    assert_equal [ [ 100, 20 ], [ 30, 5 ] ], ModelUsage.order(:id).pluck(:input, :output)
  end

  test "a background helper's usage is recorded once, when it ends" do
    @a.update!(payer: @b)
    usage = counts(input: 60, output: 6).merge("models" => { "anthropic/claude-opus-5-5" => counts(input: 60, output: 6) }, "tools" => {})

    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/a-1/submissions}).to_return(status: 202, body: { id: 1, status: "queued" }.to_json)

    2.times { Helper.report(@conversation, call_id: "toolu_h", task: "Look it up", state: "done", answer: "Found.", usage: usage) }

    helper = @conversation.helpers.sole
    assert_equal [ [ @a.id, @agent.id, helper.id, @b.id, "anthropic/claude-opus-5-5", 60, 6 ] ],
      ModelUsage.pluck(:workspace_id, :agent_id, :helper_id, :payer_id, :model, :input, :output)
  end

  test "a background helper on a lighter model has its usage recorded under that model, not its agent's" do
    usage = counts(input: 40, output: 4).merge("models" => { "anthropic/claude-haiku-5-5" => counts(input: 40, output: 4) }, "tools" => {})
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/a-1/submissions}).to_return(status: 202, body: { id: 1, status: "queued" }.to_json)

    Helper.report(@conversation, call_id: "toolu_h", task: "Look it up", state: "done", answer: "Found.", usage: usage,
      model: "anthropic/claude-haiku-5-5", thinking_level: "low")

    assert_not_equal "anthropic/claude-haiku-5-5", @agent.model
    assert_equal [ [ "anthropic/claude-haiku-5-5", 40, 4 ] ], ModelUsage.pluck(:model, :input, :output)
    assert_equal "anthropic/claude-haiku-5-5", @conversation.helpers.sole.model
  end

  test "a run's usage carries the file it was filed under, then the label clears, so the next run is untagged" do
    @conversation.update!(filed_under: "EXAMPLE-FILE-A")

    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 100, output: 20) }, tools: { "web_search" => counts(input: 4, output: 1) })
    assert_equal [ [ "anthropic/claude-opus-5-5", "EXAMPLE-FILE-A" ], [ nil, "EXAMPLE-FILE-A" ] ], ModelUsage.order(:id).pluck(:model, :filed_under)
    assert_nil @conversation.reload.filed_under

    finish_run(models: { "anthropic/claude-opus-5-5" => counts(input: 130, output: 25) }, tools: { "web_search" => counts(input: 4, output: 1) })
    assert_equal [ "EXAMPLE-FILE-A", "EXAMPLE-FILE-A", nil ], ModelUsage.order(:id).pluck(:filed_under)
  end

  test "a page load that finds the run ended records it under its file and clears it; one mid-run keeps it" do
    @conversation.update!(filed_under: "EXAMPLE-FILE-B")
    usage = ->(input) { counts(input: input, output: 1).merge("models" => { "anthropic/claude-opus-5-5" => counts(input: input, output: 1) }, "tools" => {}) }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/a-1\?}).to_return(
      { body: { status: "running", usage: usage.(10) }.to_json }, { body: { status: "idle", usage: usage.(30) }.to_json })

    @conversation.refresh_status!
    assert_equal "EXAMPLE-FILE-B", @conversation.reload.filed_under, "the run still works"

    @conversation.refresh_status!
    assert_equal [ [ 10, "EXAMPLE-FILE-B" ], [ 20, "EXAMPLE-FILE-B" ] ], ModelUsage.order(:id).pluck(:input, :filed_under)
    assert_nil @conversation.reload.filed_under
  end

  test "a background helper keeps the file its thread was filed under when it started" do
    usage = counts(input: 60, output: 6).merge("models" => { "anthropic/claude-opus-5-5" => counts(input: 60, output: 6) }, "tools" => {})
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/a-1/submissions}).to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    @conversation.update!(filed_under: "EXAMPLE-FILE-A")

    Helper.started(@conversation, call_id: "toolu_h", task: "Look it up")
    @conversation.update!(filed_under: "EXAMPLE-FILE-B")
    Helper.report(@conversation, call_id: "toolu_h", task: "Look it up", state: "done", answer: "Found.", usage: usage)

    assert_equal "EXAMPLE-FILE-A", @conversation.helpers.sole.filed_under
    assert_equal [ [ 60, "EXAMPLE-FILE-A" ] ], ModelUsage.pluck(:input, :filed_under)
  end

  test "a mid-run refresh records an unfiled delta before the agent files the rest" do
    @agent.switch_tool("file_under", true)
    route = "anthropic/claude-opus-5-5"
    usage = counts(input: 10, output: 1).merge("models" => { route => counts(input: 10, output: 1) }, "tools" => {})
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/a-1\?}).to_return(body: { status: "running", usage: usage }.to_json)

    @conversation.refresh_status!
    assert_equal [ [ 10, nil ] ], ModelUsage.order(:id).pluck(:input, :filed_under)

    arguments = { "label" => "EXAMPLE-FILE-A" }
    payload = invocation_payload(@conversation, tool: "file_under", arguments: arguments, call_id: "toolu_label")
    Invocation.receive(@conversation, task_id: payload[:taskId], call_id: "toolu_label", tool: "file_under", arguments: arguments, digest: payload[:digest])
    assert_equal "EXAMPLE-FILE-A", @conversation.reload.filed_under

    finish_run(models: { route => counts(input: 30, output: 5) })
    assert_equal [ [ 10, nil ], [ 20, "EXAMPLE-FILE-A" ] ], ModelUsage.order(:id).pluck(:input, :filed_under)
    assert_nil @conversation.reload.filed_under
  end

  test "a helper's start report keeps its label even if the end report arrives during a different file" do
    usage = counts(input: 60, output: 6).merge("models" => { "anthropic/claude-opus-5-5" => counts(input: 60, output: 6) }, "tools" => {})
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/a-1/submissions}).to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    @conversation.update!(filed_under: "EXAMPLE-FILE-A")

    helper = Helper.report(@conversation, call_id: "toolu_h", task: "Look it up", state: "running")
    assert_equal "EXAMPLE-FILE-A", helper.filed_under
    @conversation.update!(filed_under: "EXAMPLE-FILE-B")
    assert_equal helper.id, Helper.started(@conversation, call_id: "toolu_h", task: "Look it up").id
    2.times { Helper.report(@conversation, call_id: "toolu_h", task: "Look it up", state: "done", answer: "Found.", usage: usage) }
    assert_equal [ [ 60, "EXAMPLE-FILE-A" ] ], ModelUsage.where(helper: helper).pluck(:input, :filed_under)
  end

  test "a helper without a recorded start does not take the current file from its end report" do
    usage = counts(input: 60, output: 6).merge("models" => { "anthropic/claude-opus-5-5" => counts(input: 60, output: 6) }, "tools" => {})
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/a-1/submissions}).to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    @conversation.update!(filed_under: "EXAMPLE-FILE-B")

    helper = Helper.report(@conversation, call_id: "toolu_h", task: "Look it up", state: "done", answer: "Found.", usage: usage)
    assert_equal helper.id, Helper.started(@conversation, call_id: "toolu_h", task: "Look it up").id
    assert_nil helper.reload.filed_under
    assert_equal [ [ 60, nil ] ], ModelUsage.where(helper: helper).pluck(:input, :filed_under)
  end

  private
    def finish_run(models: {}, tools: {})
      rows = models.merge(tools).values
      total = %w[ input output cacheRead cacheWrite totalTokens ].to_h { |key| [ key, rows.sum { it[key] } ] }
      usage = total.merge("cost" => { "estimatedTotal" => nil, "basis" => "price_unavailable" }, "models" => models, "tools" => tools)
      @conversation.receive_frame(seq: 1, busy: false, tail: "", failure: nil, usage: usage)
    end

    def counts(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0)
      { "input" => input, "output" => output, "cacheRead" => cacheRead, "cacheWrite" => cacheWrite,
        "totalTokens" => input + output + cacheRead + cacheWrite, "cost" => cost }
    end
end
