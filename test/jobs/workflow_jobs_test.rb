require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A run moves on in WorkflowRunJob, and every minute in WorkflowSweepJob, so
# a sidecar that is down, or a job lost with the app, delays a run but never
# loses it, and nothing starts twice.
class WorkflowJobsTest < ActiveJob::TestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @conversation = create_conversation(create_user.agents.sole)
    @run = @conversation.workflows.create!(name: "Hotels", kind: "fan_out", steps: [ { "task" => "One." }, { "task" => "Two." } ]).start(call_id: "toolu_w")
    clear_enqueued_jobs
  end
  teardown { remove_sidecar_settings }

  test "a sidecar that is down is asked again later, from where the run stood" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return(status: 503, body: { error: "unavailable" }.to_json)
    assert_enqueued_with(job: WorkflowRunJob, args: [ @run ]) { WorkflowRunJob.perform_now(@run) }
    assert_equal [ [ "running", nil ], [ "pending", nil ] ], @run.steps.reload.map { [ it.state, it.started_at ] }

    starts = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return { |request|
      starts << JSON.parse(request.body)["callId"]
      { body: { started: starts.count(starts.last) == 1 }.to_json } }
    perform_enqueued_jobs
    assert_equal %w[ running running ], @run.steps.reload.map(&:state)
    assert @run.steps.all?(&:started_at)
    assert_equal @run.steps.map(&:call_id), starts
  end

  test "the sweep gives every unsettled run a job of its own, and none to a settled one" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 503, body: { error: "unavailable" }.to_json)
    undelivered = @conversation.workflows.create!(name: "Told", kind: "fan_out", steps: [ { "task" => "Look." } ]).start(call_id: "toolu_x")
    undelivered.update!(state: "done")
    settled = @conversation.workflows.create!(name: "Done", kind: "fan_out", steps: [ { "task" => "Look." } ]).start(call_id: "toolu_y")
    settled.update!(state: "done", delivered_at: Time.current)
    cancelled = @conversation.workflows.create!(name: "Gone", kind: "fan_out", steps: [ { "task" => "Look." } ]).start(call_id: "toolu_z")
    cancelled.update!(state: "cancelled")
    clear_enqueued_jobs

    WorkflowSweepJob.perform_now
    assert_equal [ @run, undelivered ].map(&:to_global_id).map(&:to_s), enqueued_jobs.map { it[:args].first["_aj_globalid"] }
  end
end
