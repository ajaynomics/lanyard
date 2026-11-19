require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A workflow is a plain definition (Workflow), each time it runs a
# Workflow::Run of Workflow::Steps. The sidecar is stubbed at Rails' HTTP client.
class WorkflowTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper
  include ActionCable::TestHelper

  setup do
    install_sidecar_settings
    @conversation = create_conversation(create_user.agents.sole)
    @starts = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return { |request|
      @starts << JSON.parse(request.body)["callId"]
      { body: { started: true }.to_json } }
  end
  teardown { remove_sidecar_settings }

  test "a definition names itself, says how it runs and holds one to ten tasks" do
    workflow = @conversation.workflows.new(name: "Hotels", kind: "fan_out", steps: [ { "task" => "Look." } ])
    assert workflow.valid?
    assert_equal "1 helper at once", workflow.shape
    assert_equal "2 steps in order", @conversation.workflows.new(kind: "pipeline", steps: [ {}, {} ]).shape
    assert_not @conversation.workflows.new(name: "", kind: "fan_out", steps: [ { "task" => "Look." } ]).valid?
    assert_not @conversation.workflows.new(name: "x", kind: "loop", steps: [ { "task" => "Look." } ]).valid?
    assert_not @conversation.workflows.new(name: "x", kind: "pipeline", steps: []).valid?
    assert_not @conversation.workflows.new(name: "x", kind: "pipeline", steps: Array.new(11) { { "task" => "Look." } }).valid?
    assert_not @conversation.workflows.new(name: "x", kind: "pipeline", steps: [ { "task" => " " } ]).valid?
    assert_not @conversation.workflows.new(name: "x", kind: "pipeline", steps: [ "Look." ]).valid?
  end

  test "a run's steps are named by the run, in order, and the run starts in a job" do
    run = nil
    assert_enqueued_with(job: WorkflowRunJob) do
      run = @conversation.workflows.create!(name: "Hotels", kind: "pipeline", steps: [ { "task" => "One." }, { "task" => "Two." } ]).start(call_id: "toolu_w")
    end
    assert_equal [ [ 1, "workflow-#{run.id}-1", "One.", "pending" ], [ 2, "workflow-#{run.id}-2", "Two.", "pending" ] ],
      run.steps.map { [ it.position, it.call_id, it.task, it.state ] }
    assert_predicate run, :running?
  end

  test "a step the sidecar refuses outright fails, saying so, and a pipeline goes no further" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return(status: 409, body: { error: "conversation_not_started" }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    run = @conversation.workflows.create!(name: "Hotels", kind: "pipeline", steps: [ { "task" => "One." }, { "task" => "Two." } ]).start(call_id: "toolu_w")
    perform_enqueued_jobs { run.advance }
    assert_equal [ "failed", "it couldn't start (conversation_not_started)" ], [ run.steps.first.state, run.steps.first.reason ]
    assert_equal %w[ failed skipped ], run.steps.reload.map(&:state)
    assert_predicate run.reload, :failed?
    assert run.delivered_at
  end

  test "a start that lands after the person cancelled stops the helper it started" do
    run = @conversation.workflows.create!(name: "Hotels", kind: "fan_out", steps: [ { "task" => "One." } ]).start(call_id: "toolu_w")
    step = run.steps.sole
    cancels = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return { |request|
      Workflow::Step.where(id: step.id).update_all(state: "cancelled") # tenancy-ok: the person's Cancel, while the sidecar starts it
      { body: { started: true }.to_json } }
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return { |request|
      cancels << JSON.parse(request.body)["callId"]
      { body: { cancelled: true, count: 0, tools: [] }.to_json } }
    step.start
    assert_equal [ step.call_id ], cancels
  end

  test "a refusal for lack of room leaves a step another job started meanwhile as it is" do
    run = @conversation.workflows.create!(name: "Hotels", kind: "fan_out", steps: [ { "task" => "One." } ]).start(call_id: "toolu_w")
    step = run.steps.sole
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return { |request|
      Workflow::Step.where(id: step.id).update_all(started_at: Time.current) # tenancy-ok: the other job, which got there first
      { status: 429, body: { error: "helpers_busy" }.to_json } }
    assert_equal false, step.start
    assert_predicate step.reload, :running?
    assert step.started_at
  end

  test "a step's helper works from its start, before it first reports, and is found by the report; a start refused makes none" do
    run = @conversation.workflows.create!(name: "Hotels", kind: "fan_out", steps: [ { "task" => "One." }, { "task" => "Two." } ]).start(call_id: "toolu_w")
    first, second = run.steps.to_a
    assert first.start
    helper = @conversation.helpers.sole
    assert_equal [ first.call_id, "One.", "running" ], [ helper.call_id, helper.task, helper.state ]
    assert_equal 1, Conversation::StatusLine.new(@conversation).helpers_working
    assert_equal helper, Helper.report(@conversation, call_id: first.call_id, task: "One.", state: "running")

    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return(status: 429, body: { error: "helpers_busy" }.to_json)
    assert_equal false, second.start
    assert_equal [ first.call_id ], @conversation.helpers.reload.pluck(:call_id)
  end

  test "a run's steps at work, each with its helper, in order, for a Message to each" do
    run = @conversation.workflows.create!(name: "Hotels", kind: "fan_out", steps: [ { "task" => "One." }, { "task" => "Two." }, { "task" => "Three." } ]).start(call_id: "toolu_w")
    run.advance
    first, second, third = run.steps.reload.to_a
    Helper.report(@conversation, call_id: second.call_id, task: "Two.", state: "done", answer: "Found.")
    assert_equal({ first => first.helper, third => third.helper }, run.reload.working_helpers)
    assert_empty @conversation.workflows.create!(name: "Later", kind: "fan_out", steps: [ { "task" => "One." } ]).start(call_id: "toolu_x").working_helpers
  end

  test "a run is drawn as the database has it, not as a job's older copy" do
    run = @conversation.workflows.create!(name: "Hotels", kind: "fan_out", steps: [ { "task" => "One." }, { "task" => "Two." } ]).start(call_id: "toolu_w")
    run.steps.load
    Workflow::Step.where(id: run.steps.first.id).update_all(state: "done", answer: "Found.") # tenancy-ok: a report, in another process
    shown = capture_turbo_stream_broadcasts(@conversation) { run.show }
    assert_includes shown.sole.to_html, "1. Done: One."
  end

  test "a cancelled run's note is for the agent, never the person's bubble" do
    run = @conversation.workflows.create!(name: "Hotels", kind: "fan_out", steps: [ { "task" => "One." } ]).start(call_id: "toolu_w")
    run.update!(state: "cancelled")
    note = Workflow::Run.cancellations_for_agent([ run ])
    assert_equal "\n\n<workflows_cancelled>\nThe person cancelled the workflow “Hotels”. No step had finished.\n</workflows_cancelled>", note
    message = @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Hi#{note}")
    assert_equal "Hi", message.content
  end
end
