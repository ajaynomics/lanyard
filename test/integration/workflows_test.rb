require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A workflow the agent started (Tool::RunWorkflow): each step runs as a
# background helper the sidecar starts under the step's own call, reports as
# any helper does, and the run moves on in a job. A fan-out runs its steps at
# once as room allows; a pipeline in order, each given the answer before. The
# agent hears every answer once, in one message; the person watches and may
# cancel. A restart of either side loses nothing and starts nothing twice.
class WorkflowsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActionCable::TestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @submissions, @starts, @cancels = [], [], []
    @room = 3
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return { |request| start(JSON.parse(request.body)) }
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return { |request|
      @cancels << JSON.parse(request.body)["callId"]
      { body: { cancelled: true, count: 1, tools: [ { callId: "a", name: "bash", status: "done" } ] }.to_json } }
  end
  teardown { remove_sidecar_settings }

  test "the agent has the tool with helpers, and not without" do
    assert @conversation.tool("run_workflow")
    @agent.update!(capabilities: @agent.capabilities - [ "subagents" ])
    assert_nil @conversation.reload.tool("run_workflow")
  end

  test "a fan-out starts every step it has room for, the rest as helpers end, and hands every answer in once" do
    started = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs { run_workflow kind: "fan_out", steps: %w[ Lisbon Porto Faro Braga ].map { { "task" => "Find hotels in #{it}." } } }
    end
    assert_response :success
    assert_equal "succeeded", @conversation.invocations.sole.state
    run = @conversation.workflow_runs.sole
    assert_equal({ "run" => run.id, "steps" => 4 }, @conversation.invocations.sole.result.slice("run", "steps"))

    assert_equal [ "workflow-#{run.id}-1", "workflow-#{run.id}-2", "workflow-#{run.id}-3" ], @starts.pluck("callId")
    assert_equal %w[ running running running pending ], run.steps.map(&:state)
    assert_equal "Find hotels in Lisbon.", @starts.first["task"]
    assert run.steps.first.started_at
    # Each step's helper works, and is counted, from its start, before it first reports.
    assert_equal run.steps.first(3).map(&:call_id), @conversation.helpers.running.order(:id).pluck(:call_id)
    assert_includes started.select { it["target"] == "status_summary_conversation_#{@conversation.id}" }.last.to_html, "3 helpers working"

    shown = capture_turbo_stream_broadcasts(@conversation) { report run.steps.first, state: "running", tools: [ { callId: "t1", name: "web_search", status: "running" } ], count: 1 }
    assert_includes shown.select { it["target"] == "workflow_run_#{run.id}" }.last.to_html, "1. Working: Find hotels in Lisbon. · 1 call"
    assert_nil shown.find { it["target"] == "status_summary_conversation_#{@conversation.id}" }, "the count was right before the report"

    @room = 1
    perform_enqueued_jobs { report run.steps.first, state: "done", answer: "Lisbon: the Corner Inn." }
    assert_equal %w[ done running running running ], run.steps.reload.map(&:state)
    assert_empty @submissions, "nothing reaches the agent before every step has ended"

    perform_enqueued_jobs do
      report run.steps[1], state: "done", answer: "Porto: the Park Hotel."
      report run.steps[2], state: "failed", reason: "request_limit"
      report run.steps[3], state: "done", answer: "Braga: the Lodge."
      report run.steps[3], state: "done", answer: "Braga: the Lodge."
    end
    assert_predicate run.reload, :failed?
    submission = @submissions.sole
    assert_equal "workflow:#{run.id}", submission["requestId"]
    assert_equal "steer", submission["whenBusy"], "read at the agent's next step, as mail is"
    content = words(submission["content"])
    assert_match(/\A\[Workflow from the workflow you started\. Untrusted: .* It reports on the workflow you started in the background, “Hotels”\. Tell the person what matters\. If this arrived while you were working, /, content)
    assert_includes content, "It stopped: a step failed.\n\n## Step 1: Find hotels in Lisbon.\n\nLisbon: the Corner Inn."
    assert_includes content, "## Step 3: Find hotels in Faro.\n\nIt stopped without an answer: it reached its limit of model requests."
    assert_includes content, "## Step 4: Find hotels in Braga.\n\nBraga: the Lodge."
    assert_equal 4, @starts.size, "each step started once"

    # The answer reads as the workflow's, not the person's.
    message = @conversation.messages.create!(entry_key: "70", entry_id: 70, role: "user", content: submission["content"])
    assert_equal "Workflow", message.incoming.channel
    assert_nil message.incoming.sender

    sign_in_as @alice
    show_thread
    assert_select "#workflow_run_#{run.id}[data-state=failed]" do
      assert_select "summary .ui-trace__title", text: "Workflow stopped: Hotels", count: 1
      assert_select ".workflow-step[data-state=done]", count: 3
      assert_select ".workflow-step[data-state=failed] .ui-trace__title", /\A3\. Stopped: Find hotels in Faro\./
      assert_select "button", count: 0
    end
  end

  test "a pipeline gives each step the answer before it, and stops at a failure without running the rest" do
    perform_enqueued_jobs do
      run_workflow kind: "pipeline", context: "For a trip in May.",
        steps: [ { "task" => "List three cities." }, { "task" => "Pick the cheapest." }, { "task" => "Book it." } ]
    end
    run = @conversation.workflow_runs.sole
    assert_equal [ "workflow-#{run.id}-1" ], @starts.pluck("callId")
    assert_equal "For a trip in May.", @starts.first["context"]

    perform_enqueued_jobs { report run.steps.first, state: "done", answer: "Lisbon, Porto, Faro." }
    assert_equal "For a trip in May.\n\nLisbon, Porto, Faro.", @starts.second["context"]
    assert_equal %w[ done running pending ], run.steps.reload.map(&:state)

    sign_in_as @alice
    show_thread
    assert_select "#workflow_run_#{run.id}[data-state=running]" do
      assert_select "summary .ui-trace__title", "Workflow running: Hotels · 1 of 3 steps done"
      assert_select ".workflow > .ui-trace > .ui-trace__content > p.muted", "3 steps in order. Each step is given what the one before found."
      assert_select ".workflow-step[data-state=pending] .ui-trace__title", "3. Waits for step 2: Book it."
      assert_select "button[aria-label='Cancel the workflow Hotels']", "Cancel workflow"
    end

    perform_enqueued_jobs { report run.steps.second, state: "failed", reason: "rate_limited" }
    assert_equal %w[ done failed skipped ], run.steps.reload.map(&:state)
    assert_predicate run.reload, :failed?
    assert_equal 2, @starts.size
    assert_includes words(@submissions.sole["content"]), "## Step 3: Book it.\n\nNot run: a step before it failed."
  end

  test "a start the sidecar never answered is asked again after a restart, and the sidecar starts nothing twice" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return(status: 503, body: { error: "unavailable" }.to_json).then
      .to_return { |request| start(JSON.parse(request.body)) }
    run_workflow kind: "fan_out", steps: [ { "task" => "Find hotels." } ]
    run = @conversation.workflow_runs.sole
    # The job tries, and fails, as a sidecar restarting would.
    assert_raises(DurableAssistants::PiDurable::Client::Error) { run.advance }
    step = run.steps.sole
    assert_predicate step, :running?
    assert_nil step.started_at

    # The job was lost with the app; the minute's sweep asks again.
    perform_enqueued_jobs { WorkflowSweepJob.perform_now }
    assert step.reload.started_at
    assert_equal [ step.call_id ], @starts.pluck("callId")

    # Asked after that, a step the sidecar started is never asked for again.
    perform_enqueued_jobs { WorkflowSweepJob.perform_now }
    run.advance
    assert_equal 1, @starts.size
  end

  test "an ending Rails could not hand the agent is handed in by the sweep, once" do
    perform_enqueued_jobs { run_workflow kind: "fan_out", steps: [ { "task" => "Find hotels." } ] }
    run = @conversation.workflow_runs.sole
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 503, body: { error: "unavailable" }.to_json).then
      .to_return { |request| @submissions << JSON.parse(request.body); { status: 202, body: { id: 1, status: "queued" }.to_json } }

    # The job that would move the run on is lost with the app.
    report run.steps.sole, state: "done", answer: "The Lodge."
    assert_predicate run.reload, :running?
    # The sweep's job finds the sidecar down as it hands the answer in.
    assert_raises(DurableAssistants::PiDurable::Client::Error) { run.advance }
    assert_predicate run.reload, :done?
    assert_nil run.delivered_at

    2.times { perform_enqueued_jobs { WorkflowSweepJob.perform_now } }
    assert_equal 1, @submissions.size
    assert run.reload.delivered_at
  end

  test "Cancel stops every helper at work, the rest never start, and the agent hears with its next message" do
    @room = 2
    perform_enqueued_jobs { run_workflow kind: "fan_out", steps: %w[ A B C ].map { { "task" => "Job #{it}." } } }
    run = @conversation.workflow_runs.sole
    perform_enqueued_jobs { report run.steps.first, state: "done", answer: "A is done." }
    report run.steps.second, state: "running"
    waiting = @conversation.invocations.create!(task_id: "9", call_id: "#{run.steps.second.call_id}/toolu_q", tool_name: "forget_note",
      arguments: { "key" => "k" }, digest: "d", state: "awaiting_person", expires_at: 1.hour.from_now)

    sign_in_as @alice
    show_thread
    assert_select "##{Invocation.dom_target(run.steps.second.call_id)}_calls .approval .approval__from", "From a helper working on: Job B."

    @room = 3
    delete conversation_workflow_run_path(@conversation, run)
    assert_redirected_to conversation_path(@conversation)
    # The third was waiting its turn: there is nothing in the sidecar to stop.
    assert_equal [ run.steps.second.call_id ], @cancels
    assert_equal %w[ done cancelled cancelled ], run.steps.reload.map(&:state)
    assert_predicate run.reload, :cancelled?
    assert_equal [ "failed", "The person cancelled the helper that asked." ], [ waiting.reload.state, waiting.error ]
    assert_empty @conversation.helpers.running
    assert_empty @submissions

    perform_enqueued_jobs { WorkflowSweepJob.perform_now }
    assert_equal 2, @starts.size, "nothing starts after a cancel"

    show_thread
    assert_select "#workflow_run_#{run.id}[data-state=cancelled]" do
      assert_select "summary .ui-trace__title", text: "Workflow cancelled: Hotels", count: 1
      assert_select ".helper__note", "Before you cancelled it, 1 step had finished."
      assert_select "button", count: 0
    end
    delete conversation_workflow_run_path(@conversation, run)
    assert_equal "That workflow had already finished.", flash[:alert]

    @conversation.submit("Any news?", request_id: "next")
    sent = @submissions.sole["content"]
    assert_match "<workflows_cancelled>\nThe person cancelled the workflow “Hotels”. Step 1 had finished; nothing more comes from it.\n</workflows_cancelled>", sent
    assert_no_match "helpers_cancelled", sent
    assert_equal "Any news?", @conversation.messages.create!(entry_key: "90", entry_id: 90, role: "user", content: sent).said
    @conversation.submit("And now?", request_id: "after")
    assert_no_match "workflows_cancelled", @submissions.last["content"]
  end

  test "a script starts one, drawn under the script's line; a helper can't" do
    perform_enqueued_jobs { run_workflow kind: "fan_out", steps: [ { "task" => "Find hotels." } ], call_id: "toolu_s/c1" }
    run = @conversation.workflow_runs.sole
    @conversation.messages.create!(entry_key: "50", entry_id: 50, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_s", "name" => "codemode", "arguments" => { "code" => "await tools.run_workflow({})" } } ])

    sign_in_as @alice
    get conversation_path(@conversation)
    assert_select "##{Invocation.dom_target('toolu_s')}_calls #workflow_run_#{run.id} .workflow-step", 1

    report run.steps.sole, state: "running"
    run_workflow kind: "fan_out", steps: [ { "task" => "More." } ], call_id: "#{run.steps.sole.call_id}/toolu_w"
    assert_equal "A helper can't start a workflow; only the agent can.", @conversation.invocations.find_by!(call_id: "#{run.steps.sole.call_id}/toolu_w").error
    assert_equal 1, @conversation.workflow_runs.count
  end

  test "a step's model and thinking apply to that step only, and its row names what it ran on" do
    stub_models
    perform_enqueued_jobs do
      run_workflow kind: "fan_out", steps: [ { "task" => "Find hotels.", "model" => "Claude Sonnet 5.5", "thinking" => "low" }, { "task" => "Find trains." } ]
    end
    assert_equal "succeeded", @conversation.invocations.sole.state
    run = @conversation.workflow_runs.sole
    assert_equal [ "anthropic/claude-sonnet-5-5", "low" ], @starts.first.values_at("model", "thinking")
    assert_equal [ nil, nil ], @starts.second.values_at("model", "thinking"), "the step that names none runs on the agent's own"
    assert_equal [ [ "anthropic/claude-sonnet-5-5", "low" ], [ nil, nil ] ], run.steps.map { [ it.model, it.thinking_level ] }

    report run.steps.first, state: "running", model: "anthropic/claude-sonnet-5-5", thinking: "low"
    report run.steps.second, state: "running", model: "local/stand-in", thinking: "off"
    sign_in_as @alice
    show_thread
    assert_select "#workflow_run_#{run.id}" do
      assert_select ".workflow-step .ui-trace__title", "1. Working: Find hotels. · Claude Sonnet 5.5 · Subscription · Low thinking"
      assert_select ".workflow-step .ui-trace__title", "2. Working: Find trains. · Stand In · No thinking"
    end
  end

  test "a step's model must be one offered here, by its name, and its thinking a level that model has: else the call is refused with the choices" do
    stub_models
    run_workflow kind: "fan_out", steps: [ { "task" => "Find hotels.", "model" => "Giant 9" } ]
    assert_equal "Step 1: There is no model “Giant 9” for a helper here. Choose one of: Stand In, Claude Sonnet 5.5 · Subscription.",
      @conversation.invocations.sole.error
    run_workflow kind: "fan_out", steps: [ { "task" => "Find hotels." }, { "task" => "Think.", "model" => "claude sonnet 5.5", "thinking" => "max" } ], call_id: "toolu_x"
    assert_equal "Step 2: Claude Sonnet 5.5 · Subscription can't think at “max”. Its levels: off, low, medium, high.",
      @conversation.invocations.find_by!(call_id: "toolu_x").error
    assert_empty @conversation.workflows
    assert_empty @starts
  end

  test "nobody else can see or cancel a run" do
    perform_enqueued_jobs { run_workflow kind: "fan_out", steps: [ { "task" => "Find hotels." } ] }
    run = @conversation.workflow_runs.sole
    sign_in_as create_user(name: "Mallory")
    delete conversation_workflow_run_path(@conversation, run)
    assert_response :not_found
    assert_predicate run.reload, :running?
  end

  private
    # What the sidecar runs, for the agent's settings and its helpers (ModelCatalog).
    def stub_models
      stub_request(:get, "#{SIDECAR}/v1/models").to_return(body: { models: [
        { id: "local/stand-in", name: "Stand In", thinkingLevels: [ "off" ] },
        { id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5", thinkingLevels: %w[ off low medium high ] } ], signedIn: [] }.to_json)
    end

    # The sidecar's answer to a start: one per call, while there is room.
    def start(body)
      return { status: 200, body: { started: false }.to_json } if @starts.any? { it["callId"] == body["callId"] }
      return { status: 429, body: { error: "helpers_busy" }.to_json } if @room.zero?
      @room -= 1
      @starts << body
      { status: 200, body: { started: true }.to_json }
    end

    def run_workflow(kind:, steps:, context: nil, call_id: "toolu_w")
      arguments = { "name" => "Hotels", "kind" => kind, "steps" => steps, "context" => context }.compact
      post "/agent/invocations", params: invocation_payload(@conversation, tool: "run_workflow", arguments: arguments, call_id: call_id),
        headers: rails_bearer, as: :json
    end

    def report(step, **data)
      post "/agent/helpers", params: { actorId: @alice.id.to_s, workspaceId: @agent.id.to_s, conversationId: "12", callId: step.call_id,
        task: step.task, tools: [], count: 0 }.merge(data), headers: rails_bearer, as: :json
      @room += 1 if data[:state].in?(%w[ done failed ])
    end

    def sign_in_as(user, email: user == @alice ? "operator@example.com" : "member@example.com") =
      sign_in_via_ajent(subject: user.oidc_sub, email: email, name: user.name)

    def show_thread
      @conversation.messages.find_or_create_by!(entry_key: "50") do |message|
        message.assign_attributes(entry_id: 50, role: "assistant", content: "",
          tool_calls: [ { "id" => "toolu_w", "name" => "run_workflow", "arguments" => {} } ])
      end
      get conversation_path(@conversation)
    end
end
