require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/concourse_test_helper"

# Concourse's push webhook (its contract: task d7c63efc, 2026-11-08): a notice
# with no mail, admitted by its token, that wakes a read of the event log.
class ConcoursePushesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ConcourseTestHelper
  include ActiveJob::TestHelper

  setup do
    @concourse_agent = create_concourse_agent(create_user.agents.sole, checked_at: Time.current)
  end

  test "connecting on a public https address registers a push with a fresh token; saving again rotates it" do
    stub_concourse_session
    registered = []
    stub_request(:put, "#{ORIGIN}/api/push_config").with { registered << JSON.parse(it.body) }
      .to_return(status: 200, body: { url: "x", updated_at: "now" }.to_json)

    with_setting(:app, :url, "https://agents.example.test") do
      assert @concourse_agent.check
      first = @concourse_agent.reload.push_token
      assert_equal({ "url" => "https://agents.example.test/concourse/#{@concourse_agent.id}/push", "token" => first }, registered.last)
      assert_match(/\A[[:graph:]]{16,256}\z/, first)

      @concourse_agent.check
      assert_not_equal first, @concourse_agent.reload.push_token
      assert_equal @concourse_agent.push_token, registered.last["token"]
    end
    assert_not_includes ConcourseAgent.connection.select_value("SELECT push_token FROM concourse_agents WHERE id = #{@concourse_agent.id}"), @concourse_agent.push_token
  end

  test "an address Concourse can't reach, or a refusal, keeps the listener" do
    stub_concourse_session
    @concourse_agent.check
    assert_not @concourse_agent.reload.pushed?, "http://localhost: nothing asked"

    stub_concourse(:put, "api/push_config", { error: "invalid_params" }, status: 422)
    with_setting(:app, :url, "https://agents.example.test") { @concourse_agent.check }
    assert_not @concourse_agent.reload.pushed?
    ConcourseSweepJob.perform_now
    assert_enqueued_with job: ConcourseListenJob, args: [ @concourse_agent ]
  end

  test "a notice with the token wakes a read; the wrong token, none, or another agent's is refused" do
    @concourse_agent.update!(push_token: "a" * 32)
    notice = ->(token, id: @concourse_agent.id) {
      post concourse_push_path(id), params: { agent: "acme/assistant", event_id: 42, task_id: "task-1", kind: "message" }.to_json,
        headers: { "Content-Type" => "application/json", "Concourse-Event-Id" => "42", "X-A2A-Notification-Token" => token }.compact
    }

    notice.("a" * 32)
    assert_response :no_content
    assert_enqueued_with job: ConcourseListenJob, args: [ @concourse_agent ]

    clear_enqueued_jobs
    [ "b" * 32, nil, "a" * 31 ].each { notice.(it); assert_response :unauthorized }
    other = create_concourse_agent(create_user(name: "Bob").agents.sole)
    notice.("a" * 32, id: other.id)
    assert_response :unauthorized, "an agent with no push takes no notice"
    notice.("a" * 32, id: 0)
    assert_response :unauthorized
    assert_no_enqueued_jobs only: ConcourseListenJob
  end

  test "a flood is answered 429, which Concourse retries later" do
    @concourse_agent.update!(push_token: "a" * 32)
    61.times { post concourse_push_path(@concourse_agent), headers: { "X-A2A-Notification-Token" => "a" * 32 } }
    assert_response :too_many_requests
  end

  test "rung, it reads what is new without waiting and stops; it starts no listener of its own, and the sweep starts none" do
    @concourse_agent.update!(push_token: "a" * 32)
    stub_concourse_session
    reads = stub_request(:get, "#{ORIGIN}/api/events?limit=100&wait=0")
      .to_return(body: { events: [], cursor: 0, more: false, oldest: 1 }.to_json)

    ConcourseListenJob.perform_now(@concourse_agent)
    ConcourseSweepJob.perform_now

    assert_requested reads, times: 1
    assert_no_enqueued_jobs only: ConcourseListenJob
  end

  test "taking the agent off Concourse stops the pushes" do
    sign_in_via_ajent # Alice has the starter, so this person starts with none of their own
    agent = User.find_by!(oidc_sub: "42").start_agent("Robin's assistant") # tenancy-ok: test reads the person it signed in
    create_concourse_agent(agent, push_token: "a" * 32)
    stub_concourse_session
    stopped = stub_concourse(:delete, "api/push_config", {}, status: 204)

    delete agent_concourse_agent_path(agent)

    assert_requested stopped
    assert_nil agent.reload.concourse_agent
  end
end
