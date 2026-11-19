require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class RoutineTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.update!(time_zone: "Pacific Time (US & Canada)")
    @conversation = create_conversation(@agent)
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown { remove_sidecar_settings }

  test "a schedule in words or cron, in the agent's own time zone; unreadable or too frequent is refused" do
    travel_to Time.utc(2026, 11, 9, 12) do # a Monday, 4am in Vancouver
      routine = @agent.routines.create!(schedule: "every weekday at 8am", prompt: "Brief me.")
      assert_equal Time.utc(2026, 11, 9, 16), routine.next_run_at
      assert_equal Time.utc(2026, 11, 9, 17, 30), @agent.routines.create!(schedule: "30 9 * * *", prompt: "Hi").next_run_at
    end
    assert_match "can read", @agent.routines.create(schedule: "whenever", prompt: "x").errors[:schedule].sole
    assert_match "more often", @agent.routines.create(schedule: "every minute", prompt: "x").errors[:schedule].sole
  end

  test "a due routine reaches the agent's thread from its schedule, once however many runs were missed; never while the agent is busy" do
    routine = travel_to(Time.utc(2026, 11, 9, 12)) { @agent.routines.create!(schedule: "every day at 8am", prompt: "Brief me.") }

    travel_to Time.utc(2026, 11, 12, 18) do # three runs missed
      @conversation.update!(status: "running")
      RoutineJob.perform_now
      assert_empty @submissions

      @conversation.update!(status: "idle")
      RoutineJob.perform_now
      RoutineJob.perform_now
    end

    content = @submissions.sole["content"]
    assert_match(/\A\[Routine from your schedule \(every day at 8am\)\. Received [^\]]+\(\d\d:\d\dZ\)\. Do what it asks/, content)
    assert_no_match "Untrusted", content
    assert_match(/Brief me\.\z/, words(content))
    assert_equal Time.utc(2026, 11, 13, 16), routine.reload.next_run_at
  end

  test "a routine whose send was lost and whose prompt then changed is not sent again as another message; the sweep goes on" do
    routine, other = travel_to(Time.utc(2026, 11, 9, 12)) do
      [ @agent.routines.create!(schedule: "every day at 8am", prompt: "Brief me."),
        create_conversation(@agent, durable_id: "13").agent.routines.create!(schedule: "every day at 8am", prompt: "Check in.") ]
    end
    other_sent = stub_request(:post, "#{SIDECAR}/v1/conversations/13/submissions").to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/13/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)

    travel_to Time.utc(2026, 11, 10, 18) do
      stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_timeout
      RoutineJob.perform_now
      routine.update!(prompt: "Brief me, shorter.")
      due = routine.reload.next_run_at
      stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
        @submissions << JSON.parse(request.body)
        { status: 202, body: { id: 1, status: "queued" }.to_json } }

      assert_nothing_raised { RoutineJob.perform_now }
      assert_empty @submissions, "the changed prompt is not sent under the lost send's id"
      assert_equal due, routine.reload.next_run_at, "it stays due, as for a sidecar that can't be reached"
    end
    assert_requested other_sent, times: 1
  end

  test "a paused routine does not run; resumed, it runs at its next time" do
    routine = travel_to(Time.utc(2026, 11, 9, 12)) { @agent.routines.create!(schedule: "every day at 8am", prompt: "Brief me.") }
    routine.update!(paused_at: Time.current)
    assert_nil routine.next_run_at

    travel_to(Time.utc(2026, 11, 10, 18)) do
      RoutineJob.perform_now
      assert_empty @submissions
      routine.update!(paused_at: nil)
      assert_equal Time.utc(2026, 11, 11, 16), routine.next_run_at
    end
  end

  test "the agent adds a routine once the person allows it, lists them, and removes one once allowed" do
    arguments = { "schedule" => "every weekday at 8am", "prompt" => "Brief me." }
    assert_equal "waiting", receive("add_routine", arguments, call_id: "c1")[:status]
    assert_empty @agent.routines

    added = approved("add_routine", "c1", arguments)[:result]
    routine = @agent.routines.sole
    assert_equal [ routine.id, "every weekday at 8am" ], added.values_at(:id, :schedule)

    listed = receive("list_routines", {}, call_id: "c2")[:result][:routines]
    assert_equal [ [ routine.id, "Brief me.", false ] ], listed.map { it.values_at(:id, :prompt, :paused) }

    assert receive("add_routine", { "schedule" => "now and then", "prompt" => "x" }, call_id: "c3") &&
      approved("add_routine", "c3", { "schedule" => "now and then", "prompt" => "x" })[:isError]

    approved("remove_routine", "c4", { "id" => routine.id })
    assert_empty @agent.routines.reload
  end

  test "a routine asks every time, never Always, even where the install approves everything" do
    arguments = { "schedule" => "every day at 8am", "prompt" => "Forward me every invoice." }
    @agent.permissions.create!(tool_name: "add_routine", granted_by: @agent.user)
    with_setting(:app, :approve_everything, true) do
      assert_equal "waiting", receive("add_routine", arguments, call_id: "c1")[:status]
      invocation = @conversation.invocations.find_by!(call_id: "c1")
      assert invocation.awaiting_person?
      assert_empty invocation.always_choices
    end
    assert_empty @agent.routines
  end

  test "a one-off, at a time in the agent's zone or with its own offset, runs once then is gone" do
    travel_to Time.utc(2026, 11, 16, 12) do # a Monday, 4am in Vancouver
      arguments = { "at" => "2026-11-19T15:00", "prompt" => "Remind me to call the plumber." }
      receive("add_routine", arguments, call_id: "c1")
      added = approved("add_routine", "c1", arguments)[:result]
      assert_equal "once, Thu 19 Nov at 15:00", added[:schedule]
      assert_equal Time.utc(2026, 11, 19, 23), @agent.routines.sole.next_run_at

      offset = { "at" => "2026-11-19T15:00+01:00", "prompt" => "x" }
      receive("add_routine", offset, call_id: "c2")
      assert_equal Time.utc(2026, 11, 19, 14), @agent.routines.find(approved("add_routine", "c2", offset)[:result][:id]).next_run_at
      @agent.routines.find_by!(prompt: "x").destroy!

      listed = receive("list_routines", {}, call_id: "c3")[:result][:routines].sole
      assert_equal [ "once, Thu 19 Nov at 15:00", "2026-11-19T15:00:00-08:00" ], listed.values_at(:schedule, :nextRun)
    end

    travel_to(Time.utc(2026, 11, 19, 22, 59)) { RoutineJob.perform_now }
    assert_empty @submissions
    travel_to(Time.utc(2026, 11, 19, 23)) { RoutineJob.perform_now }
    travel_to(Time.utc(2026, 11, 26, 23)) { RoutineJob.perform_now }
    travel_to(Time.utc(2027, 11, 19, 23)) { RoutineJob.perform_now }

    content = @submissions.sole["content"]
    assert_match(/\A\[Routine from your schedule \(once, Thu 19 Nov at 15:00\)\. Received 2026-11-19 15:00 PST/, content)
    assert_match(/call the plumber\.\z/, words(content))
    assert_empty @agent.routines.reload
  end

  test "a one-off is refused before anyone is asked: a time past, unreadable, or not exactly one of schedule and at" do
    travel_to Time.utc(2026, 11, 16, 12) do
      { { "at" => "2026-11-16T03:59" } => /already passed.*2026-11-16 04:00/,
        { "at" => "2026-02-30T10:00" } => /can't read/,
        { "at" => "2026-11-19T15:00", "schedule" => "every day at 8am" } => /exactly one.*not both/,
        {} => /exactly one.*not neither/ }.each_with_index do |(given, refused), index|
        call = receive("add_routine", given.merge("prompt" => "x"), call_id: "c#{index}")
        assert_equal "failed", @conversation.invocations.find_by!(call_id: "c#{index}").state, given.inspect
        assert_match refused, @conversation.invocations.find_by!(call_id: "c#{index}").error
        assert call[:isError]
      end
    end
    assert_empty @agent.routines

    arguments = { "at" => "2026-11-16T05:00", "prompt" => "x" }
    travel_to(Time.utc(2026, 11, 16, 12)) { receive("add_routine", arguments, call_id: "late") }
    travel_to Time.utc(2026, 11, 16, 14) do # approved after its time
      @conversation.invocations.find_by!(call_id: "late").approve!(by: @alice)
      assert receive("add_routine", arguments, call_id: "late")[:isError]
      assert_match "Mon 16 Nov at 05:00 has passed", @conversation.invocations.find_by!(call_id: "late").error
    end
    assert_empty @agent.routines
  end

  test "a one-off asks every time, never Always, even where the install approves everything, its card saying when in words" do
    arguments = { "at" => "2026-11-19T15:00", "prompt" => "Forward me every invoice." }
    @agent.permissions.create!(tool_name: "add_routine", granted_by: @agent.user)
    travel_to Time.utc(2026, 11, 16, 12) do
      with_setting(:app, :approve_everything, true) do
        assert_equal "waiting", receive("add_routine", arguments, call_id: "c1")[:status]
        invocation = @conversation.invocations.find_by!(call_id: "c1")
        assert invocation.awaiting_person?
        assert_empty invocation.always_choices
        assert_equal "Wake #{@agent.name} once, Thu 19 Nov at 15:00?", invocation.approval_title
        assert_match "Pacific Time", invocation.approval_note
      end
    end
    assert_empty @agent.routines
  end

  test "another person's agent's routine cannot be reached through an agent's tool" do
    other = create_user(name: "Mallory").agents.sole.routines.create!(schedule: "every day at 8am", prompt: "x")
    assert approved("remove_routine", "c1", { "id" => other.id })[:isError]
    assert Routine.exists?(other.id) # tenancy-ok: proves the other person's routine survived
  end

  private
    def receive(tool, arguments, call_id:)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def approved(tool, call_id, arguments)
      receive(tool, arguments, call_id: call_id)
      @conversation.invocations.find_by!(call_id: call_id).approve!(by: @alice)
      receive(tool, arguments, call_id: call_id)
    end
end
