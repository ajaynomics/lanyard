require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/concourse_test_helper"
require_relative "../test_helpers/push_test_helper"

class ConversationDeliveryJobTest < ActiveJob::TestCase
  include AgentTestHelper
  include ConcourseTestHelper
  include PushTestHelper

  setup do
    install_sidecar_settings
    install_push_settings
    @owner = create_user
    @agent = @owner.agents.sole
    @computer = @agent.create_computer!(provider: "sprites", state: "on")
    @thread = create_conversation(@agent)
    @identity = create_concourse_agent(@agent)
    @peer_task = @thread.peer_tasks.create!(task_id: "task-1", peer: "acme/robin", direction: "outbound", state: "TASK_STATE_SUBMITTED")
    subscribe(@owner)
    stub_concourse_session
    stub_concourse(:get, "agents/7/tasks?pageSize=50", { tasks: [], blockedTasks: [], nextPageToken: "" })
    stub_concourse(:get, "api/tasks/task-1", concourse_task(state: "TASK_STATE_COMPLETED", status_message: [ "a-1", "Booked for Friday." ]))
    @sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return do |request|
      @sent << JSON.parse(request.body)
      { status: 202, body: { id: "1", status: "placed" }.to_json }
    end
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    remove_sidecar_settings
    remove_push_settings
  end

  test "a Concourse reply waits in a delayed job and uses its original envelope once the hold is released" do
    hold_and_receive
    submission = @thread.submissions.sole
    prepared = JSON.parse(submission.payload)
    assert_equal [ submission ], ActiveJob::Arguments.deserialize(delivery_jobs.sole.fetch("arguments"))
    assert @peer_task.reload.delivered?("a-1")
    assert_nil submission.accepted_at

    perform_enqueued_jobs(only: ConversationDeliveryJob, at: Time.current)
    assert_operator delivery_jobs.sole.fetch(:at), :>, Time.current.to_f
    assert_still_waiting

    @computer.release!
    retry_delivery
    assert_equal prepared.except("definition"), @sent.sole.except("definition")
    assert_nil @sent.sole.dig("definition", "computer", "held")
    assert submission.reload.accepted_at

    entries = [ { id: "reply-1", entryId: 1, role: "assistant", content: "I have the booking." } ]
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries})
      .to_return(body: { entries: entries, cursor: 1, more: false }.to_json)
    @thread.reload.receive_frame(seq: 1, busy: false, tail: "", failure: nil)
    assert_equal "I have the booking.", @thread.messages.sole.content
    assert_equal "idle", @thread.reload.shown_status
    assert_empty error_notices
    assert_empty delivery_jobs
  end

  test "a computer still held on the tenth attempt stops with the existing notice, once" do
    hold_and_receive
    submission = @thread.submissions.sole
    perform_enqueued_jobs(only: ConversationDeliveryJob, at: Time.current)
    8.times do
      retry_delivery
      assert_still_waiting
    end

    retry_delivery
    assert_empty @sent
    assert_empty delivery_jobs
    assert_nil submission.reload.accepted_at
    assert_equal "error", @thread.reload.shown_status
    assert_equal "this computer is being rebuilt; try again shortly.", Conversation::Failure.text(@thread.failure)
    assert_equal [ "Stopped: this computer is being rebuilt; try again shortly." ], error_notices.pluck("body")

    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "done", failure: nil, pendingInputs: [] }.to_json)
    @thread.refresh_status!
    assert_equal "error", @thread.reload.shown_status, "the sidecar's previous run did not see the held submission"
    assert_equal 1, error_notices.size

    @computer.release!
    @thread.receive("A new message.", from: "Robin", via: "Campfire", request_id: "campfire-2")
    assert_equal "running", @thread.reload.shown_status
  end

  test "an unheld Concourse reply is delivered once without a delivery job" do
    2.times { ConcourseSweepJob.perform_now(@identity) }

    assert_match(/Booked for Friday\./, @sent.sole.fetch("content"))
    assert @thread.submissions.sole.accepted_at
    assert_empty delivery_jobs
    assert_empty error_notices
  end

  test "a duplicate delivery job does not send an accepted envelope again, even during another hold" do
    hold_and_receive
    submission = @thread.submissions.sole
    @computer.release!
    perform_enqueued_jobs(only: ConversationDeliveryJob)
    assert submission.reload.accepted_at
    @computer.hold!

    ConversationDeliveryJob.perform_now(submission)

    assert_equal submission.request_id, @sent.sole.fetch("requestId")
    assert_empty delivery_jobs
    assert_empty error_notices
  end

  private
    def delivery_jobs = enqueued_jobs.select { it["job_class"] == "ConversationDeliveryJob" }

    def hold_and_receive
      @computer.hold!
      ConcourseSweepJob.perform_now(@identity)
      assert_still_waiting
    end

    def assert_still_waiting
      assert_empty @sent.map { it.dig("definition", "computer", "held") }, "Rails passed a held computer to the sidecar"
      assert_nil @thread.reload.failure
      assert_empty error_notices
    end

    def retry_delivery
      scheduled = Time.at(delivery_jobs.sole.fetch(:at))
      travel_to(scheduled.ceil) { perform_enqueued_jobs(only: ConversationDeliveryJob, at: Time.current) }
    end

    def error_notices
      enqueued_jobs.filter_map do |job|
        payload = job["arguments"].last
        payload if job["job_class"] == "Push::DeliveryJob" && payload["kind"] == "error"
      end
    end
end
