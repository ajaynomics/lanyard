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
