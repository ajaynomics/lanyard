require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/concourse_test_helper"

class ConcourseListenJobTest < ActiveJob::TestCase
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    @concourse_agent = create_concourse_agent(create_user.agents.sole)
    stub_concourse_session
  end

  test "a quarter hour of listening, then it listens again shortly" do
    polls = stub_request(:get, "#{ORIGIN}/api/events?limit=100&wait=25").to_return do
      travel ConcourseAgent::LISTEN_FOR + 1.second # the poll waited; the quarter hour is up
      { status: 200, body: { "events" => [], "cursor" => 0, "more" => false, "oldest" => 1 }.to_json }
    end
    ConcourseListenJob.perform_now(@concourse_agent)
    assert_requested polls, times: 1
    assert_enqueued_with(job: ConcourseListenJob, args: [ @concourse_agent ], at: ConcourseListenJob::RECONNECT.from_now)
  end

  test "a failed read waits before trying again; an agent taken off Concourse stops" do
    stub_concourse(:get, "api/events?limit=100&wait=25", { error: "busy" }, status: 503)
    ConcourseListenJob.perform_now(@concourse_agent)
    assert_enqueued_with(job: ConcourseListenJob, args: [ @concourse_agent ], at: ConcourseListenJob::AFTER_FAILURE.from_now)

    clear_enqueued_jobs
    @concourse_agent.destroy!
    ConcourseListenJob.perform_now(@concourse_agent)
    assert_no_enqueued_jobs only: ConcourseListenJob
  end

  test "one listener per agent: another is discarded, not queued, and its lock outlasts a listen" do
    assert_equal :discard, ConcourseListenJob.concurrency_on_conflict
    assert_operator ConcourseListenJob.concurrency_duration, :>, ConcourseAgent::LISTEN_FOR
  end

  test "the minute's sweep starts a listener for each connected agent" do
    @concourse_agent.update!(checked_at: Time.current)
    create_concourse_agent(create_user(name: "Bob").agents.sole) # never connected

    ConcourseSweepJob.perform_now

    assert_enqueued_jobs 1, only: ConcourseListenJob
    assert_enqueued_with(job: ConcourseListenJob, args: [ @concourse_agent ])
  end
end
