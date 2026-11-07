require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/concourse_test_helper"

class ConcourseListenJobTest < ActiveJob::TestCase
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    @agent = create_concourse_agent(create_user.bots.sole)
    stub_concourse_session
  end

  test "each doorbell hint sweeps, and a closed stream listens again shortly" do
    stub_request(:get, "#{ORIGIN}/api/doorbell").to_return(status: 200, headers: { "Content-Type" => "text/event-stream" },
      body: "event: ready\ndata: {}\n\nevent: ping\ndata: {}\n\n")

    ConcourseListenJob.perform_now(@agent)

    assert_enqueued_jobs 2, only: ConcourseSweepJob
    assert_enqueued_with(job: ConcourseListenJob, args: [ @agent ], at: ConcourseListenJob::RECONNECT.from_now)
  end

  test "a failed doorbell waits before trying again; a bot taken off Concourse stops" do
    stub_request(:get, "#{ORIGIN}/api/doorbell").to_return(status: 503)
    ConcourseListenJob.perform_now(@agent)
    assert_enqueued_with(job: ConcourseListenJob, args: [ @agent ], at: ConcourseListenJob::AFTER_FAILURE.from_now)

    clear_enqueued_jobs
    @agent.destroy!
    ConcourseListenJob.perform_now(@agent)
    assert_no_enqueued_jobs only: ConcourseListenJob
  end

  test "one listener per bot: another is discarded, not queued" do
    assert_equal :discard, ConcourseListenJob.concurrency_on_conflict
    assert_operator ConcourseListenJob.concurrency_duration, :>, DurableAssistants::Concourse::Client::DOORBELL_LIMIT
  end

  test "the minute's sweep starts a listener for each connected bot" do
    @agent.update!(checked_at: Time.current)
    create_concourse_agent(create_user(name: "Bob").bots.sole) # never connected

    ConcourseSweepJob.perform_now

    assert_enqueued_jobs 1, only: ConcourseListenJob
    assert_enqueued_with(job: ConcourseListenJob, args: [ @agent ])
  end
end
