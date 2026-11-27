require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The safety net under a turn that stops moving (pi#11892 was one): the
# sidecar says `stalled` when a run's tasks are there and none runs or sleeps.
class ConversationRecoveryTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    @conversation = create_conversation(create_user.agents.sole)
    @conversation.update!(status: "running", execution_status: "running")
    @state = { status: "stalled" }
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return { { body: @state.to_json } }
    @cancel = stub_request(:post, "#{SIDECAR}/v1/conversations/12/cancellations")
      .with { |request| !JSON.parse(request.body).key?("preserveQueue") }.to_return(body: { cancelled: true }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "a run stalled past the limit is ended and says why; a moment of it is left alone" do
    ConversationRecoveryJob.perform_now
    assert_equal "running", @conversation.reload.status
    assert_not_requested @cancel

    travel Conversation::STALL_LIMIT - 1.second do
      ConversationRecoveryJob.perform_now
      assert_not_requested @cancel
    end
    travel Conversation::STALL_LIMIT + 1.second do
      ConversationRecoveryJob.perform_now
    end

    assert_requested @cancel, times: 1
    assert_equal [ "error", "stalled", nil ], @conversation.reload.values_at(:status, :failure, :stalled_at)
    assert_match "stopped making progress", ApplicationController.helpers.failure_text(@conversation.failure)
    @conversation.receive_frame(seq: 9, busy: false, tail: "", failure: "aborted")
    assert_equal "stalled", @conversation.reload.failure, "the sidecar's own word for it doesn't hide why"
  end

  test "a run that moves again starts the clock over, and the sweep settles a lost final frame" do
    ConversationRecoveryJob.perform_now
    assert @conversation.reload.stalled_at

    @state = { status: "running" }
    ConversationRecoveryJob.perform_now
    assert_nil @conversation.reload.stalled_at

    @state = { status: "done" }
    ConversationRecoveryJob.perform_now
    assert_equal "idle", @conversation.reload.status
    assert_not_requested @cancel
  end

  test "a run Rails can't vouch for is asked about; a card waiting after its run ended asks nothing of the sidecar" do
    @conversation.update!(status: "running", execution_status: "unknown")
    other = create_conversation(create_user(name: "Bo").agents.sole, durable_id: "13")
    other.update!(status: "waiting", execution_status: "idle")
    @state = { status: "done" }

    ConversationRecoveryJob.perform_now

    assert_equal %w[ idle idle ], @conversation.reload.values_at(:status, :execution_status)
    assert_not_requested :get, %r{/v1/conversations/13}
  end

  test "an unreachable sidecar is asked again next minute" do
    @conversation.update!(status: "waiting")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(status: 503, body: { error: "not_ready" }.to_json)

    assert_nothing_raised { ConversationRecoveryJob.perform_now }
    assert_equal "waiting", @conversation.reload.status
  end

  # Invocation #2350 (campfire_say), live: its turn was cancelled while the post
  # ran, so the sidecar never asked again, and it stayed "running" for days.
  test "an outside call still running after the sidecar's own wait has ended is settled as lost; a slow one is left alone" do
    @conversation.update!(status: "idle", execution_status: "idle")
    abandoned = @conversation.invocations.create!(task_id: "18624", call_id: "toolu_abandoned", tool_name: "campfire_say",
      arguments: { "room" => 1, "text" => "On my way" }, digest: "d", state: "running")
    slow = @conversation.invocations.create!(task_id: "18700", call_id: "toolu_slow", tool_name: "campfire_say",
      arguments: { "room" => 1, "text" => "Still posting" }, digest: "e", state: "running")
    abandoned.update_columns(updated_at: (Invocation::WAIT + 1.minute).ago)
    slow.update_columns(updated_at: 10.minutes.ago)

    log = capture_log { ConversationRecoveryJob.perform_now }

    assert_equal [ "failed", "campfire_say: #{Invocation::LOST}" ], abandoned.reload.values_at(:state, :error)
    assert_match "invocation #{abandoned.id}", log
    assert_no_match "invocation #{slow.id}", log
    assert_equal "running", slow.reload.state
  end

  # A call may succeed in Rails while the sidecar still holds its wait.
  # The sweep rings the wait's doorbell, logs it and asks again next minute.
  test "a wait the sidecar still holds for a call Rails has answered is rung and logged, and the run is asked about again" do
    answered = @conversation.invocations.create!(task_id: "task-answered", call_id: "call-answered", tool_name: "concourse_get",
      arguments: { "task" => "t1" }, digest: "d", state: "succeeded", result: { "state" => "TASK_STATE_COMPLETED" })
    @state = { status: "waiting", pendingInputs: [ { id: "person:task-answered:call-answered", kind: "person", expiresAt: 1.day.from_now.to_i * 1000 } ] }
    @ring = stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes").with(body: hash_including(key: "task-answered:call-answered"))
      .to_return(body: { rung: true }.to_json)

    log = capture_log { perform_enqueued_jobs { ConversationRecoveryJob.perform_now } }

    assert_requested @ring, times: 1
    assert_match "invocation #{answered.id}", log
    assert_equal %w[ running unknown ], @conversation.reload.values_at(:status, :execution_status), "no typing dots while Rails asks again"
    assert_not_equal "running", @conversation.shown_status

    @state = { status: "done", pendingInputs: [] }
    ConversationRecoveryJob.perform_now
    assert_equal %w[ idle idle ], @conversation.reload.values_at(:status, :execution_status)
  end

  private
    def capture_log
      io, was = StringIO.new, Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = was
    end
end
