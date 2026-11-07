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
    @conversation.update!(status: "running")
    @state = { status: "stalled" }
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return { { body: @state.to_json } }
    @cancel = stub_request(:post, "#{SIDECAR}/v1/conversations/12/cancellations").to_return(body: { cancelled: true }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "a run stalled past the limit is ended as the person's Stop would, and says why; a moment of it is left alone" do
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

  test "an unreachable sidecar is asked again next minute" do
    @conversation.update!(status: "waiting")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(status: 503, body: { error: "not_ready" }.to_json)

    assert_nothing_raised { ConversationRecoveryJob.perform_now }
    assert_equal "waiting", @conversation.reload.status
  end
end
