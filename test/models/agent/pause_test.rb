require "test_helper"
require "action_mailbox/test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"
require_relative "../../test_helpers/email_test_helper"

# A paused agent (#52): nothing it is sent reaches the sidecar, what was
# waiting there comes back to be held, and resuming sends it all once, in order.
class Agent::PauseTest < ActiveSupport::TestCase
  # Campfire posts a room's message to a bot only with its @mention (#258).
  CAMPFIRE_MENTION = %(<action-text-attachment content-type="application/vnd.campfire.mention"></action-text-attachment>).freeze

  include AgentTestHelper
  include ConcourseTestHelper
  include EmailTestHelper
  include ActionMailbox::TestHelper
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper

  # The sidecar's inbox as pi-durable keeps it: one submission per request id,
  # queued while a run goes, and a withdrawn one never taken in again under
  # its own id (agent/test/pause.test.mjs proves the real one does this).
  class Inbox
    attr_reader :read, :queue
    attr_accessor :busy, :lose_next, :down, :before_submit, :refuse, :fail_once

    def initialize
      @ids, @queue, @read, @withdrawn, @next, @busy = {}, [], [], [], 30, true
    end

    def submit(body)
      before_submit&.call(body)
      id = @ids[body["requestId"]] ||= (@next += 1).tap do |new_id|
        item = { "id" => new_id.to_s, "mode" => body["whenBusy"], "text" => Array(body["content"]).first.to_s, "pictures" => 0 }
        busy ? @queue << item : @read << item["text"]
      end
      { id: id, status: @withdrawn.include?(id) ? "unanswered" : (@queue.any? { it["id"] == id.to_s } ? "queued" : "placed") }
    end

    def withdraw(id)
      item = @queue.find { it["id"] == id }
      @queue.delete(item)
      @withdrawn << id.to_i if item
      { withdrawn: item.present? }
    end

    def take_in! = @read.concat(@queue.map { it["text"] }).tap { @queue.clear }
  end

  setup do
    install_sidecar_settings
    install_email_settings
    @agent = create_user.agents.sole
    Agent.where(id: @agent.id).update_all(email_name: "travel")
    @agent.reload
    @conversation = create_conversation(@agent)
    @inbox = Inbox.new
    base = "#{SIDECAR}/v1/conversations/12"
    unavailable = { status: 503, body: { error: "unavailable" }.to_json }
    @submissions = stub_request(:post, "#{base}/submissions").to_return do |request|
      next unavailable if @inbox.down
      next { status: @inbox.fail_once.tap { @inbox.fail_once = nil }, body: { error: "unauthorized" }.to_json } if @inbox.fail_once
      next { status: 422, body: { error: "tool_limit" }.to_json } if JSON.parse(request.body)["requestId"] == @inbox.refuse
      answer = @inbox.submit(JSON.parse(request.body))
      raise Net::ReadTimeout if @inbox.lose_next && !(@inbox.lose_next = false)
      { status: 202, body: answer.to_json }
    end
    stub_request(:get, base).with(query: hash_including({})).to_return do
      @inbox.down ? unavailable : { body: { status: "running", queued: @inbox.queue }.to_json }
    end
    stub_request(:delete, %r{\A#{base}/queued/\d+}).to_return { |request| { body: @inbox.withdraw(request.uri.path.split("/").last).to_json } }
    stub_request(:get, %r{\A#{base}/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "while paused no message from anyone reaches the sidecar; each is held, in order, and the agent may make no request" do
    @agent.pause
    assert @agent.reload.paused?

    @conversation.submit("Are you there?", request_id: "person-1")
    receive_inbound_email_from_mail(from: "Air Canada <info@aircanada.example>", to: "travel@agents.example",
      subject: "Your booking", body: "Flight AC 123.", message_id: "abc@aircanada.example")
    @agent.create_campfire_bot!(bot_key: "4-abc123").receive(
      { "user" => { "name" => "Maya" }, "room" => { "id" => 3, "name" => "Trips" }, "message" => { "id" => 41, "body" => { "plain" => "Book the train.", "html" => CAMPFIRE_MENTION } } })

    assert_not_requested @submissions
    assert_equal [ "person-1", "email:#{@agent.id}:abc@aircanada.example", "campfire:#{@agent.id}:41" ], @conversation.held.map(&:request_id)
    assert_equal "Are you there?", words(@conversation.held.first.shown["text"])
  end

  test "what waited in the sidecar comes back to be held; resuming sends everything once, in order, across a lost answer and a restart" do
    @conversation.submit("First, book Lisbon", request_id: "person-1")
    @conversation.receive("Flight moved.", from: "info@aircanada.example", via: "Email", request_id: "email:1")
    assert_equal 2, @inbox.queue.size

    @agent.pause
    assert_empty @inbox.queue, "taken back from the sidecar"
    assert_equal [ "First, book Lisbon", "Flight moved." ], @conversation.held.map { words(it.shown["text"]).lines.last }
    @agent.pause
    assert_equal 2, @conversation.held.count, "pausing again holds nothing twice"
    @conversation.submit("And a hotel", request_id: "person-2")

    @inbox.busy = false
    @inbox.lose_next = true
    @agent.resume
    assert_not @agent.reload.paused?, "it may run again"
    assert_enqueued_with job: ConversationHoldingJob, args: [ @conversation ]

    perform_enqueued_jobs
    perform_enqueued_jobs { ConversationHoldingJob.perform_later(@conversation) }

    assert_equal [ "First, book Lisbon", "Flight moved.", "And a hotel" ], @inbox.read.map { words(it).lines.last }
    assert_empty @conversation.held
  end

  test "a routine due again and again while paused is held once, and runs once after" do
    routine = @agent.routines.create!(prompt: "Check the flights", schedule: "every hour")
    @inbox.busy = false
    @agent.pause

    2.times do |hour|
      routine.update_column(:next_run_at, 1.minute.ago)
      RoutineJob.perform_now
    end

    assert_equal 1, @conversation.held.count { it.request_id.start_with?("routine:#{routine.id}:") }
    assert_not_requested @submissions
    @agent.resume
    perform_enqueued_jobs
    assert_equal 1, @inbox.read.size
  end

  test "a one-off due while paused is held, and runs once after" do
    routine = travel_to(1.hour.ago) { @agent.routines.create!(prompt: "Call the plumber", once_at: 30.minutes.from_now) }
    @inbox.busy = false
    @agent.pause

    2.times { RoutineJob.perform_now }

    assert_equal 1, @conversation.held.count { it.request_id.start_with?("routine:#{routine.id}:") }
    assert_not Routine.exists?(routine.id) # tenancy-ok: proves the one-off is gone once held
    assert_not_requested @submissions
    @agent.resume
    perform_enqueued_jobs
    assert_equal [ "Call the plumber" ], @inbox.read.map { words(it).lines.last }
  end

  test "a held Concourse task stays open: the peer sees the agent paused, as working" do
    concourse = create_concourse_agent(@agent)
    stub_concourse_session
    stub_concourse(:get, "agents/7/tasks?pageSize=50", { tasks: [ concourse_task(messages: [ [ "m-1", "Book Friday?" ] ]) ], blockedTasks: [], nextPageToken: "" })
    working = stub_request(:patch, "#{ORIGIN}/tasks/task-1")
      .with { JSON.parse(it.body, symbolize_names: true) in { state: "TASK_STATE_WORKING", message: { parts: [ { text: /\AAgent paused/ } ] } } }
      .to_return(headers: { "Content-Type" => "application/json" }, body: concourse_task(state: "TASK_STATE_WORKING").to_json)
    @agent.pause

    concourse.sweep

    assert_not_requested @submissions
    assert_requested working, times: 1
    assert_equal "TASK_STATE_WORKING", @agent.peer_tasks.sole.state
    assert_equal 1, @conversation.held.count
  end

  test "dropping a held Concourse message rejects its task; Campfire's and mail's are only logged; no email is ever sent" do
    concourse = create_concourse_agent(@agent)
    stub_concourse_session
    stub_concourse(:get, "agents/7/tasks?pageSize=50", { tasks: [ concourse_task(messages: [ [ "m-1", "Book Friday?" ] ]) ], blockedTasks: [], nextPageToken: "" })
    stub_request(:patch, "#{ORIGIN}/tasks/task-1").with(body: hash_including("state" => "TASK_STATE_WORKING"))
      .to_return(headers: { "Content-Type" => "application/json" }, body: concourse_task(state: "TASK_STATE_WORKING").to_json)
    rejected = stub_request(:patch, "#{ORIGIN}/tasks/task-1")
      .with(body: { state: "TASK_STATE_REJECTED", message: { parts: [ { text: "Dropped by the owner while the agent was paused." } ] } })
      .to_return(headers: { "Content-Type" => "application/json" }, body: concourse_task(state: "TASK_STATE_REJECTED").to_json)
    campfire = stub_request(:any, /campfire/)
    @agent.pause
    concourse.sweep
    receive_inbound_email_from_mail(from: "info@aircanada.example", to: "travel@agents.example", subject: "Hi", body: "Hello", message_id: "m@x")
    @agent.create_campfire_bot!(bot_key: "4-abc123").receive(
      { "user" => { "name" => "Maya" }, "room" => { "id" => 3, "name" => "Trips" }, "message" => { "id" => 41, "body" => { "plain" => "Hi", "html" => CAMPFIRE_MENTION } } })

    assert_no_emails do
      assert_no_enqueued_jobs only: MailDeliveryJob do
        @conversation.held.to_a.each(&:drop)
      end
    end

    assert_requested rejected, times: 1
    assert_equal "TASK_STATE_REJECTED", @agent.peer_tasks.sole.state
    assert_not_requested campfire
    assert_empty @conversation.held
    @agent.resume
    assert_not_requested @submissions
  end

  test "the turn a pause stopped at its next step ends idle, not as a failure, and stays so after the resume" do
    @conversation.update!(execution_status: "running", status: "running")
    @inbox.busy = false
    @agent.pause
    @agent.resume
    perform_enqueued_jobs

    @conversation.receive_frame(seq: 1, busy: false, tail: "", failure: "paused_by_owner")
    assert_equal "idle", @conversation.reload.status
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "error", failure: { reason: "paused_by_owner" }, queued: [] }.to_json)
    @conversation.refresh_status!
    assert_equal "idle", @conversation.reload.status
  end

  test "a message that comes while resuming waits behind what was held; the agent holds until all of it has gone" do
    @inbox.busy = false
    @agent.pause
    @conversation.receive("HELD-1", from: "Maya in Trips", via: "Campfire", request_id: "campfire:1")
    @conversation.receive("HELD-2", from: "Maya in Trips", via: "Campfire", request_id: "campfire:2")
    @inbox.down = true
    @agent.resume
    @inbox.down = false
    @conversation.receive("NEW-3", from: "Maya in Trips", via: "Campfire", request_id: "campfire:3")

    assert_empty @inbox.read, "nothing goes ahead of what was held"
    assert @agent.reload.paused_at, "still holding while what it held goes"
    perform_enqueued_jobs

    assert_equal %w[ HELD-1 HELD-2 NEW-3 ], @inbox.read.map { it[/HELD-\d|NEW-\d/] }
    assert_nil @agent.reload.paused_at
    assert_empty @conversation.held
  end

  test "a send that failed before the pause is neither held nor sent by the resume" do
    @inbox.busy = false
    @inbox.down = true
    assert_raises(DurableAssistants::PiDurable::Client::Error) { @conversation.submit("STALE", request_id: "person-old") }
    @inbox.down = false
    travel 1.day
    @agent.pause
    @conversation.submit("FRESH", request_id: "person-new")

    assert_equal [ "person-new" ], @conversation.held.map(&:request_id)
    @agent.resume
    perform_enqueued_jobs
    assert_equal [ "FRESH" ], @inbox.read.map { it[/STALE|FRESH/] }
  end

  test "a message whose send is under way as the pause is saved is pulled back after it" do
    @inbox.before_submit = ->(body) { (@inbox.before_submit = nil; Agent.find(@agent.id).pause) if body["requestId"] == "campfire:9" }
    @conversation.receive("RACE", from: "Maya in Trips", via: "Campfire", request_id: "campfire:9", when_busy: "steer")
    assert @agent.reload.paused?

    perform_enqueued_jobs
    assert_empty @inbox.queue
    assert_equal [ "campfire:9:held" ], @conversation.held.map(&:request_id)
  end

  test "with the sidecar down at the pause the agent is paused, and a job pulls its queue back once it answers" do
    @conversation.receive("WAITING", from: "Maya in Trips", via: "Campfire", request_id: "campfire:5", when_busy: "steer")
    @inbox.down = true
    @agent.pause
    assert @agent.reload.paused?
    @inbox.down = false

    perform_enqueued_jobs
    assert_empty @inbox.queue
    assert_equal [ "campfire:5:held" ], @conversation.held.map(&:request_id)
  end

  test "dropping one held Concourse message drops all its task holds, with one rejection" do
    concourse = create_concourse_agent(@agent)
    stub_concourse_session
    stub_concourse(:get, "agents/7/tasks?pageSize=50",
      { tasks: [ concourse_task(messages: [ [ "m-1", "Book Friday?" ], [ "m-2", "Or Saturday?" ] ]) ], blockedTasks: [], nextPageToken: "" })
    stub_request(:patch, "#{ORIGIN}/tasks/task-1").with(body: hash_including("state" => "TASK_STATE_WORKING"))
      .to_return(headers: { "Content-Type" => "application/json" }, body: concourse_task(state: "TASK_STATE_WORKING").to_json)
    rejected = stub_request(:patch, "#{ORIGIN}/tasks/task-1").with(body: hash_including("state" => "TASK_STATE_REJECTED"))
      .to_return(headers: { "Content-Type" => "application/json" }, body: concourse_task(state: "TASK_STATE_REJECTED").to_json)
    @agent.pause
    concourse.sweep
    assert_equal 2, @conversation.held.count

    @conversation.held.first.drop

    assert_empty @conversation.held
    assert_requested rejected, times: 1
  end

  test "a card waiting on the person stays pending across a pause and a resume; nothing is cancelled" do
    card = @conversation.invocations.create!(task_id: "7", call_id: "toolu_1", tool_name: "forget_note", arguments: {}, digest: "d",
      state: "awaiting_person", expires_at: 1.hour.from_now)
    cancel = stub_request(:post, "#{SIDECAR}/v1/conversations/12/cancellations")

    @agent.pause
    assert card.reload.awaiting_person?
    @agent.resume

    assert card.reload.awaiting_person?
    assert_not_requested cancel
  end

  test "pausing again while it resumes does nothing: what it held still goes once, in order" do
    @agent.pause
    %w[ A-1 B-2 C-3 ].each { say(it) }
    @agent.resume
    @inbox.before_submit = ->(body) { (@inbox.before_submit = nil; Agent.find(@agent.id).pause) if body["requestId"] == "campfire:B-2" }
    perform_enqueued_jobs
    @inbox.take_in!

    assert_equal %w[ A-1 B-2 C-3 ], @inbox.read.map { it[/[A-C]-\d/] }
    assert_nil @agent.reload.paused_at
    assert_empty @conversation.submissions.where("request_id LIKE ?", "%:held")
  end

  test "a held message can't be dropped once its resume has begun: it goes, and the resume ends" do
    @inbox.busy = false
    @agent.pause
    %w[ A-1 B-2 ].each { say(it) }
    @agent.resume

    assert_not @conversation.held.first.drop
    perform_enqueued_jobs

    assert_equal %w[ A-1 B-2 ], @inbox.read.map { it[/[A-C]-\d/] }
    assert_not @agent.reload.resuming?
  end

  test "any error while resuming is tried again a minute on, and the resume ends" do
    @inbox.busy = false
    @agent.pause
    %w[ A-1 B-2 ].each { say(it) }
    @agent.resume
    @inbox.before_submit = ->(_) { @inbox.before_submit = nil; raise ArgumentError, "unexpected" }
    clear_enqueued_jobs

    streams = capture_turbo_stream_broadcasts(@conversation) do
      freeze_time do
        ConversationHoldingJob.perform_now(@conversation)
        assert_enqueued_with job: ConversationHoldingJob, args: [ @conversation ], at: 1.minute.from_now
      end
    end
    assert streams.any? { it.to_html.include?("Trying again in a minute") }, "the person sees why it is still resuming"
    perform_enqueued_jobs

    assert_equal %w[ A-1 B-2 ], @inbox.read.map { it[/[A-C]-\d/] }
    assert_not @agent.reload.resuming?
  end

  test "a message that comes while resuming adds no job: the one resuming sends it" do
    @inbox.busy = false
    @agent.pause
    say("A-1")
    @agent.resume

    assert_no_enqueued_jobs(only: ConversationHoldingJob) { say("B-2") }
    perform_enqueued_jobs

    assert_equal %w[ A-1 B-2 ], @inbox.read.map { it[/[A-C]-\d/] }
    assert_not @agent.reload.resuming?
  end

  test "a held message the sidecar refuses for good is set aside, once, and said; the rest go and the resume ends" do
    @inbox.busy = false
    @agent.pause
    %w[ A-1 B-2 C-3 ].each { say(it) }
    @inbox.refuse = "campfire:B-2"
    @agent.resume

    streams = capture_turbo_stream_broadcasts(@conversation) { perform_enqueued_jobs }

    assert_equal %w[ A-1 C-3 ], @inbox.read.map { it[/[A-C]-\d/] }
    assert_not @agent.reload.resuming?
    assert_requested(:post, "#{SIDECAR}/v1/conversations/12/submissions", times: 1) { JSON.parse(it.body)["requestId"] == "campfire:B-2" }
    assert streams.any? { it.to_html.match?(/A held message wasn.t sent: This agent has more tools/) }, streams.map(&:to_html).join
    assert_no_enqueued_jobs only: ConversationHoldingJob
  end

  test "a 401 while resuming is the app's token, not the message: nothing is set aside, it stays resuming, and it is tried again" do
    @inbox.busy = false
    @agent.pause
    %w[ A-1 B-2 ].each { say(it) }
    @agent.resume
    @inbox.fail_once = 401
    clear_enqueued_jobs

    streams = capture_turbo_stream_broadcasts(@conversation) do
      freeze_time do
        ConversationHoldingJob.perform_now(@conversation)
        assert_enqueued_with job: ConversationHoldingJob, args: [ @conversation ], at: 1.minute.from_now
      end
    end
    assert @agent.reload.resuming?
    assert_empty @inbox.read
    assert streams.any? { it.to_html.include?("Trying again in a minute") }, streams.map(&:to_html).join
    assert streams.none? { it.to_html.match?(/A held message wasn.t sent/) }, streams.map(&:to_html).join
    perform_enqueued_jobs

    assert_equal %w[ A-1 B-2 ], @inbox.read.map { it[/[A-C]-\d/] }
    assert_not @agent.reload.resuming?
  end

  test "a raced send's copy goes before what was held after it: an idle sidecar" do
    @inbox.busy = false
    @inbox.before_submit = ->(body) { (@inbox.before_submit = nil; Agent.find(@agent.id).pause) if body["requestId"] == "campfire:R-1" }
    say("R-1")
    say("M-2")
    perform_enqueued_jobs
    @agent.reload.resume
    perform_enqueued_jobs

    assert_equal %w[ R-1 R-1 M-2 ], @inbox.read.map { it[/[A-Z]-\d/] }, "the first R-1 is the run the pause refused"
  end

  test "a raced send's copy goes before what was held after it: a busy sidecar" do
    @inbox.before_submit = ->(body) { (@inbox.before_submit = nil; Agent.find(@agent.id).pause) if body["requestId"] == "campfire:R-1" }
    say("R-1")
    say("M-2")
    perform_enqueued_jobs
    @inbox.busy = false
    @agent.reload.resume
    perform_enqueued_jobs

    assert_equal %w[ R-1 M-2 ], @inbox.read.map { it[/[A-Z]-\d/] }
  end

  test "resumed before the pause's recheck: the resume rechecks first, so the raced send is held again and sent" do
    @inbox.busy = false
    @inbox.before_submit = ->(body) { (@inbox.before_submit = nil; Agent.find(@agent.id).pause) if body["requestId"] == "campfire:R-1" }
    say("R-1")
    @agent.reload.resume
    perform_enqueued_jobs

    assert_equal %w[ R-1 R-1 ], @inbox.read.map { it[/[A-Z]-\d/] }
    assert_equal 1, @conversation.submissions.where(request_id: "campfire:R-1:held").where.not(accepted_at: nil).count
    assert_not @agent.reload.resuming?
  end

  test "an old branch thread holds nothing: a send there while paused is refused, and goes once resumed" do
    branch = @agent.conversations.create!(parent: @conversation, durable_id: "13", request_id: "r-13")
    sends = stub_request(:post, "#{SIDECAR}/v1/conversations/13/submissions").to_return(status: 202, body: { id: 99, status: "placed" }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/13}).to_return(body: { status: "idle", queued: [], entries: [], cursor: nil, more: false }.to_json)
    @agent.pause

    assert_raises(Conversation::Submission::Paused) { branch.submit("B-1", request_id: "person:B-1") }
    assert_not_requested sends
    assert_empty branch.held

    @agent.resume
    perform_enqueued_jobs
    branch.submit("B-1", request_id: "person:B-1")
    assert_requested sends, times: 1
  end

  test "a send an idle sidecar took as the pause was saved is held again, and sent on resume" do
    @inbox.busy = false
    @inbox.before_submit = ->(body) { (@inbox.before_submit = nil; Agent.find(@agent.id).pause) if body["requestId"] == "campfire:R-1" }
    say("R-1")
    perform_enqueued_jobs

    assert_equal [ "campfire:R-1:held" ], @conversation.held.map(&:request_id)
    @agent.reload.resume
    perform_enqueued_jobs
    assert_equal %w[ R-1 R-1 ], @inbox.read.map { it[/R-1/] }, "read twice: once by the run the pause refused, once after"
  end

  private
    def say(word) = @conversation.receive(word, from: "Maya in Trips", via: "Campfire", request_id: "campfire:#{word}")
end
