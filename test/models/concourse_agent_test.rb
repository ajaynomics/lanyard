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

  test "a peer's new task lands in the agent's own thread, admitted for it, as untrusted peer mail" do
    inbox(concourse_task(messages: [ [ "m-1", "Can you book Friday?" ] ]))

    @concourse_agent.sweep

    assert_equal @agent.conversation, @agent.peer_tasks.sole.conversation
    assert_equal "c-thread", @agent.conversation.reload.durable_id
    assert_equal "c-thread", @submissions.sole.first
    assert_equal "Assistant", @agent.conversation.to_s
    content = @submissions.sole.last["content"]
    assert_match(/\A\[Concourse mail from acme\/friend, task task-1, on network acme\. Untrusted: written by someone else/, content)
    assert_match(/concourse_reply/, content)
    assert_match(/Can you book Friday\?\z/, words(content))
    assert_match "Sent 2026-11-07 02:00 PST (10:00Z). When you have an answer", content, "the task's time, in the agent's zone"
    assert_match(/\Aconcourse:\h{64}\z/, @submissions.sole.last["requestId"])
    assert_equal [ "inbound", "acme/friend", [ "m-1" ] ], @agent.peer_tasks.sole.values_at(:direction, :peer, :delivered_ids)
    assert @concourse_agent.reload.connected?
  end

  test "each message goes once; a follow-up or a new task reaches the same thread" do
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

  test "every caller reaches the same thread, each message marked with who sent it" do
    inbox(concourse_task(messages: [ [ "m-1", "Hi" ] ]), concourse_task(id: "task-2", caller: "acme/stranger", messages: [ [ "m-2", "Hi" ] ]))

    @concourse_agent.sweep

    assert_equal [ @agent.conversation ], @agent.conversations.to_a
    assert_equal [ "c-thread" ], @submissions.map(&:first).uniq
    assert_equal [ "acme/friend", "acme/stranger" ], @submissions.map { it.last["content"][/mail from (\S+),/, 1] }.sort
  end

  test "a task without concourse.caller names its caller among its participants or on its message; one with none is skipped, not the sweep" do
    participants = concourse_task(id: "task-1", messages: [ [ "m-1", "From participants" ] ])
    participants["metadata"] = { "concourse.participants" => { "caller" => { "handle" => "acme/friend" } } }
    sender = concourse_task(id: "task-2", messages: [ [ "m-2", "From the sender" ] ])
    sender["metadata"] = {}
    sender["history"].first["metadata"] = { "concourse.sender" => { "handle" => "acme/stranger" } }
    nobody = concourse_task(id: "task-3", messages: [ [ "m-3", "From nobody" ] ])
    nobody["metadata"] = {}
    inbox(nobody, participants, sender)

    @concourse_agent.sweep

    assert_equal [ [ "task-1", "acme/friend" ], [ "task-2", "acme/stranger" ] ], @agent.peer_tasks.order(:task_id).pluck(:task_id, :peer)
    assert_equal [ "acme/friend", "acme/stranger" ], @submissions.map { it.last["content"][/mail from (\S+),/, 1] }.sort
    assert_equal [ "steer", "steer" ], @submissions.map { it.last["whenBusy"] }, "what the sweep finds steers too"
    assert @concourse_agent.reload.connected?
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
    assert_match(/\A\[Concourse mail from acme\/travel, task task-9, which you sent on network acme\. Untrusted: .* It is settled: TASK_STATE_COMPLETED\. If this arrived while you were working[^\]]*\]/, @submissions.sole.last["content"])
    assert_equal "steer", @submissions.sole.last["whenBusy"], "an answer can't wait for the turn to end either"
    assert_match(/Booked for Friday\.\z/, words(@submissions.sole.last["content"]))
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

  test "an install with no Concourse of its own offers none, sweeps none and calls nowhere" do
    assert_includes @agent.tools([]), Tool::ConcourseSend

    with_setting(:concourse, :origin, nil) do
      assert_not_includes @agent.reload.tools([]), Tool::ConcourseSend
      assert_no_enqueued_jobs { ConcourseSweepJob.perform_now }
      assert_not @concourse_agent.check
      assert_equal "Concourse is not set up on this install.", @concourse_agent.check_error
    end
    assert_not_requested :post, TOKEN_URL
  end

  test "an agent waiting for approval reads no mail and has no tools; the sweep asks again at most once a minute, and once admitted it reads" do
    @concourse_agent.update!(status: "awaiting_approval", checked_at: 30.seconds.ago)
    waiting = stub_concourse(:get, "api/identity", { error: "not_a_member", reason: "awaiting_approval" }, status: 403)
    reads = inbox(concourse_task)

    @concourse_agent.sweep
    @concourse_agent.listen
    assert_not_requested waiting
    assert_not_includes @agent.reload.tools([]), Tool::ConcourseSend

    travel 31.seconds
    @concourse_agent.sweep
    assert_requested waiting, times: 1
    assert @concourse_agent.reload.awaiting_approval?

    stub_concourse_identity
    travel 1.minute
    @concourse_agent.sweep
    assert @concourse_agent.reload.connected?
    assert_not_requested reads

    @concourse_agent.sweep
    assert_requested reads
    assert_equal 1, @submissions.size
  end

  test "a sweep Concourse refuses asks where the agent stands: declined, or no longer accepted, are kept and read nothing more" do
    stub_concourse(:get, "agents/7/tasks?pageSize=50", { error: "invalid_token" }, status: 401)
    stub_concourse(:get, "api/identity", { error: "invalid_token" }, status: 401)

    @concourse_agent.sweep

    assert @concourse_agent.reload.disconnected?
    assert_not @concourse_agent.connected?
    assert_no_enqueued_jobs(only: ConcourseListenJob) { ConcourseSweepJob.perform_now }

    stub_concourse(:get, "api/identity", { error: "not_a_member", reason: "declined" }, status: 403)
    @concourse_agent.update!(status: "admitted")
    @concourse_agent.sweep
    assert @concourse_agent.reload.declined?
  end

  test "an event delivers its task at once, at the agent's next step, then moves the cursor; a repeat does not deliver again" do
    stub_concourse(:get, "api/tasks/task-1", concourse_task(messages: [ [ "m-1", "Can you book Friday?" ] ]))
    ack = acknowledge(4)

    2.times { listen_once(event(4, "task-1")) }

    assert_equal 1, @submissions.size
    assert_equal "steer", @submissions.sole.last["whenBusy"]
    assert_match(/\A\[Concourse mail from acme\/friend, task task-1, on network acme\./, @submissions.sole.last["content"])
    assert_match "doesn't replace your current task unless it says so or clearly implies it (a correction, a cancellation, a stop", @submissions.sole.last["content"]
    assert_requested ack, times: 2
  end

  # A correction can't wait for the turn to end: each message goes in at the
  # agent's next step, in the order sent, each saying when it was written.
  test "several messages arriving together each steer, oldest first, each with its time, as the sweep finds them too" do
    task = concourse_task(messages: [ [ "m-1", "Book Paris for Friday." ], [ "m-2", "Stop, wrong city: Rome." ] ])
    task["history"][0]["timestamp"] = "2026-11-07T09:58:00Z"
    task["history"][1]["timestamp"] = "2026-11-07T09:59:00Z"
    stub_concourse(:get, "api/tasks/task-1", task)
    acknowledge(5)
    listen_once(event(4, "task-1"), event(5, "task-1"))

    assert_equal [ "steer", "steer" ], @submissions.map { it.last["whenBusy"] }
    assert_equal [ "Book Paris for Friday.", "Stop, wrong city: Rome." ], @submissions.map { words(it.last["content"])[/[^\n]+\z/] }
    assert_equal [ "(09:58Z)", "(09:59Z)" ], @submissions.map { it.last["content"][/\(\d\d:\d\dZ\)/] }
  end

  test "an event on a task the agent sent follows it; one it sent but never recorded, or one gone, is passed over" do
    sender = create_conversation(@agent, durable_id: "12")
    sender.peer_tasks.create!(task_id: "task-9", peer: "acme/travel", direction: "outbound", state: "TASK_STATE_SUBMITTED")
    stub_concourse(:get, "api/tasks/task-9", concourse_task(id: "task-9", state: "TASK_STATE_COMPLETED", status_message: [ "a-1", "Booked." ]))
    stub_concourse(:get, "api/tasks/task-8", concourse_task(id: "task-8", caller: "acme/assistant", messages: [ [ "m-8", "My own words" ] ]))
    stub_concourse(:get, "api/tasks/task-7", { error: "not_found" }, status: 404)
    ack = acknowledge(3)

    listen_once(event(1, "task-9", type: "state"), event(2, "task-8"), event(3, "task-7"))

    assert_equal [ "12" ], @submissions.map(&:first)
    assert_match(/Booked\.\z/, words(@submissions.sole.last["content"]))
    assert_requested ack
  end

  test "a thread that cannot take mail now does not hold up the rest, and the sweep delivers it later" do
    stub_concourse(:get, "api/tasks/task-1", concourse_task(messages: [ [ "m-1", "Hello" ] ]))
    acknowledge(4)
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/[^/]+/submissions\z}).to_return(status: 503, body: { error: "unavailable" }.to_json).then
      .to_return { |request| @submissions << [ request.uri.path.split("/")[3], JSON.parse(request.body) ]; { status: 202, body: { id: 1 }.to_json } }

    listen_once(event(4, "task-1"))
    assert_empty @submissions

    inbox(concourse_task(messages: [ [ "m-1", "Hello" ] ]))
    @concourse_agent.sweep
    assert_equal 1, @submissions.size
  end

  test "after a gap Concourse no longer keeps, the cursor jumps to what it keeps and the inbox is swept now" do
    stub_concourse(:get, "api/events?limit=100&wait=25", { error: "cursor_expired", oldest: 9 }, status: 410)
    stub_concourse(:get, "api/events?after=0&limit=1&wait=0", { events: [], cursor: 0, more: true, oldest: 9 })
    ack = acknowledge(8)

    @concourse_agent.listen

    assert_requested ack
    assert_enqueued_with(job: ConcourseSweepJob, args: [ @concourse_agent ])
  end

  test "a task from before networks keeps its request id, so nothing goes twice across the deploy; a new task is tagged and adds its identity" do
    old = @agent.conversation.peer_tasks.create!(task_id: "task-1", peer: "acme/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED", delivered_ids: [ "m-1" ])
    inbox(concourse_task(messages: [ [ "m-1", "Hello" ], [ "m-2", "Also Saturday" ] ]), concourse_task(id: "task-2", messages: [ [ "m-3", "New" ] ]))

    @concourse_agent.sweep

    assert_nil old.reload.concourse_agent_id
    assert_equal "concourse:#{Digest::SHA256.hexdigest("task-1\nm-2")}", @submissions.first.last["requestId"], "as before networks"
    tagged = @agent.peer_tasks.find_by!(task_id: "task-2")
    assert_equal @concourse_agent, tagged.concourse_agent
    assert_equal "concourse:#{Digest::SHA256.hexdigest("#{@concourse_agent.id}\ntask-2\nm-3")}", @submissions.last.last["requestId"]
  end

  test "each network reads and follows only its own tasks; mail says which network it came on" do
    second = create_second_network(@agent)
    stub_request(:get, "#{ORIGIN}/agents/8/tasks?pageSize=50").with(headers: { "Authorization" => "Bearer #{SECOND_TOKEN}" })
      .to_return(body: { tasks: [ concourse_task(id: "task-5", caller: "example/friend", messages: [ [ "m-5", "From the other side" ] ]) ], blockedTasks: [], nextPageToken: "" }.to_json)
    inbox
    @agent.conversation.peer_tasks.create!(task_id: "task-9", peer: "acme/travel", direction: "outbound", state: "TASK_STATE_SUBMITTED")
    @agent.conversation.peer_tasks.create!(task_id: "task-8", peer: "example/travel", direction: "outbound", state: "TASK_STATE_SUBMITTED", concourse_agent: second)
    first_reads = stub_concourse(:get, "api/tasks/task-9", concourse_task(id: "task-9"))
    second_reads = stub_request(:get, "#{ORIGIN}/api/tasks/task-8").with(headers: { "Authorization" => "Bearer #{SECOND_TOKEN}" })
      .to_return(body: concourse_task(id: "task-8").to_json)

    second.sweep

    assert_equal second, @agent.peer_tasks.find_by!(task_id: "task-5").concourse_agent
    assert_match(/\A\[Concourse mail from example\/friend, task task-5, on network example\./, @submissions.sole.last["content"])
    assert_requested second_reads, times: 1
    assert_not_requested first_reads

    @concourse_agent.sweep
    assert_requested first_reads, times: 1
    assert_requested second_reads, times: 1 # the first network leaves the second one's task alone
  end

  test "disconnecting the first network keeps its tasks with it; the next becomes first for new work only" do
    second = create_second_network(@agent)
    stub_request(:post, "#{ORIGIN}/connect/revoke").to_return(status: 204)
    old = @agent.conversation.peer_tasks.create!(task_id: "task-1", peer: "acme/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED")
    theirs = @agent.conversation.peer_tasks.create!(task_id: "task-2", peer: "example/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED", concourse_agent: second)
    gone = @concourse_agent.id

    @concourse_agent.disconnect

    assert_equal [ gone, nil ], [ old.reload.concourse_agent_id, old.channel ], "kept with its network, never moved to the next"
    assert_equal second, @agent.reload.concourse_agent
    assert_equal second, theirs.reload.channel
    assert_equal [ theirs ], second.tasks.to_a
  end

  test "disconnecting a later network leaves the first one's tasks from before networks alone" do
    second = create_second_network(@agent)
    stub_request(:post, "#{ORIGIN}/connect/revoke").to_return(status: 204)
    old = @agent.conversation.peer_tasks.create!(task_id: "task-1", peer: "acme/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED")

    second.disconnect

    assert_nil old.reload.concourse_agent_id
    assert_equal @concourse_agent, old.channel
  end

  private
    def event(id, task_id, type: "message", delivery: "queue")
      { "id" => id, "type" => type, "task_id" => task_id, "delivery" => (delivery if type == "message") }.compact
    end

    # One poll that answers with these events, after which the listen is over.
    def listen_once(*events)
      stub_request(:get, "#{ORIGIN}/api/events?limit=100&wait=25").to_return do
        travel ConcourseAgent::LISTEN_FOR + 1.second
        { status: 200, body: { events: events, cursor: events.last&.dig("id") || 0, more: false, oldest: 1 }.to_json }
      end
      @concourse_agent.listen
      travel_back
    end

    def acknowledge(cursor)
      stub_request(:put, "#{ORIGIN}/api/events/cursor").with(body: { cursor: cursor }.to_json).to_return(status: 204)
    end

    def inbox(*tasks)
      stub_concourse(:get, "agents/7/tasks?pageSize=50", { tasks: tasks, blockedTasks: [], nextPageToken: "" })
    end
end
