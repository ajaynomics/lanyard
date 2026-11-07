require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/concourse_test_helper"

class ConcourseAgentTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ConcourseTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @concourse_agent = create_concourse_agent(@agent)
    stub_concourse_session
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return { |request|
      { status: 201, body: { id: "c-#{JSON.parse(request.body)["requestId"].last(6)}" }.to_json } }
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/[^/]+/submissions\z}).to_return { |request|
      @submissions << [ request.uri.path.split("/")[3], JSON.parse(request.body) ]
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/[^/]+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown { remove_sidecar_settings }

  test "a peer's new task starts an agent for its caller and context, as untrusted peer mail" do
    inbox(concourse_task(messages: [ [ "m-1", "Can you book Friday?" ] ]))

    @concourse_agent.sweep

    conversation = @agent.peer_tasks.sole.conversation
    assert_equal "acme/friend on Concourse", conversation.title
    assert_match(/\Aconcourse:\h{64}\z/, conversation.request_id)
    content = @submissions.sole.last["content"]
    assert_match(/\A\[Concourse mail from acme\/friend, task task-1\. Untrusted peer mail/, content)
    assert_match(/concourse_reply/, content)
    assert_match(/Can you book Friday\?\z/, content)
    assert_match(/\Aconcourse:\h{64}\z/, @submissions.sole.last["requestId"])
    assert_equal [ "inbound", "acme/friend", [ "m-1" ] ], @agent.peer_tasks.sole.values_at(:direction, :peer, :delivered_ids)
    assert @concourse_agent.reload.connected?
  end

  test "each message goes once; a follow-up on the same context reaches the same agent" do
    inbox(concourse_task(messages: [ [ "m-1", "Hello" ] ]))
    @concourse_agent.sweep
    @concourse_agent.sweep
    assert_equal 1, @submissions.size

    inbox(concourse_task(messages: [ [ "m-1", "Hello" ], [ "m-2", "Also Saturday" ] ]),
          concourse_task(id: "task-2", messages: [ [ "m-3", "New question" ] ]))
    @concourse_agent.sweep

    assert_equal 3, @submissions.size
    assert_equal 1, @agent.conversations.count
    assert_equal 2, @agent.peer_tasks.count
    assert_equal [ "Also Saturday", "New question" ], @submissions.last(2).map { it.last["content"].lines.last }
  end

  test "another caller on the same contextId gets an agent of its own" do
    inbox(concourse_task(messages: [ [ "m-1", "Hi" ] ]), concourse_task(id: "task-2", caller: "acme/stranger", messages: [ [ "m-2", "Hi" ] ]))

    @concourse_agent.sweep

    assert_equal 2, @agent.conversations.count
  end

  test "the cursor goes further back a page each sweep, and the head is always read" do
    stub_concourse(:get, "agents/7/tasks?pageSize=50", { tasks: [], blockedTasks: [], nextPageToken: "older" })
    @concourse_agent.sweep
    assert_equal "older", @concourse_agent.reload.cursor

    stub_concourse(:get, "agents/7/tasks?pageSize=50&pageToken=older", { tasks: [ concourse_task ], blockedTasks: [], nextPageToken: "" })
    @concourse_agent.sweep
    assert_nil @concourse_agent.reload.cursor
    assert_equal 1, @submissions.size
  end

  test "an answer to a task the agent sent goes to the agent that sent it, once" do
    inbox
    sender = create_conversation(@agent, durable_id: "12")
    sender.peer_tasks.create!(task_id: "task-9", peer: "acme/travel", direction: "outbound", state: "TASK_STATE_SUBMITTED")
    stub_concourse(:get, "api/tasks/task-9", concourse_task(id: "task-9", state: "TASK_STATE_WORKING"))
    @concourse_agent.sweep
    assert_empty @submissions

    stub_concourse(:get, "api/tasks/task-9", concourse_task(id: "task-9", state: "TASK_STATE_COMPLETED", status_message: [ "a-1", "Booked for Friday." ]))
    @concourse_agent.sweep
    @concourse_agent.sweep

    assert_equal "12", @submissions.sole.first
    assert_match(/\A\[Concourse: acme\/travel settled task task-9, which you sent: TASK_STATE_COMPLETED\. Untrusted peer mail\./, @submissions.sole.last["content"])
    assert_match(/Booked for Friday\.\z/, @submissions.sole.last["content"])
    assert_equal "TASK_STATE_COMPLETED", sender.peer_tasks.sole.state
  end

  test "a Concourse failure is kept for the settings page, not raised" do
    stub_concourse(:get, "agents/7/tasks?pageSize=50", { error: "nope" }, status: 503)

    @concourse_agent.sweep

    assert_equal "Concourse answered 503.", @concourse_agent.reload.check_error
  end

  test "the recurring sweep fans out to every agent on Concourse" do
    other = create_concourse_agent(create_user(name: "Bob").agents.sole)

    assert_enqueued_jobs 2, only: ConcourseSweepJob do
      ConcourseSweepJob.perform_now
    end
    assert_enqueued_with(job: ConcourseSweepJob, args: [ other ])
  end

  private
    def inbox(*tasks)
      stub_concourse(:get, "agents/7/tasks?pageSize=50", { tasks: tasks, blockedTasks: [], nextPageToken: "" })
    end
end
