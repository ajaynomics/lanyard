require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/voipms_test_helper"

# A send whose answer never came, checked at the provider in the background
# until it is known whether it went (Dispatch#check), and the agent told.
# voip.ms and the sidecar are stubbed at HTTP; the ledger and jobs run.
class DispatchTest < ActiveSupport::TestCase
  include AgentTestHelper
  include VoipmsTestHelper
  include ActiveJob::TestHelper

  setup do
    install_voipms_settings
    install_sidecar_settings
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @agent.update!(phone_number: "6475550123")
    @conversation = create_conversation(@agent)
    @told = []
    stub_request(:post, %r{/v1/conversations/12/submissions}).to_return do |request|
      @told << JSON.parse(request.body)
      { status: 202, body: { id: @told.size, status: "queued" }.to_json }
    end
  end

  teardown do
    remove_sidecar_settings
    remove_voipms_settings
  end

  test "a call lost mid-send is looked up, and found, it went: the agent is told, with voip.ms's id" do
    taken = voipms_taking_then_hanging
    dispatch = lost_mid_send("On my way.")
    # voip.ms took it, and the call ended before its answer was recorded.
    DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "On my way.")

    travel(Dispatch::CHECK_AFTER + 1.second) { check_and_tell }
    assert_equal [ "sent", "10863123" ], [ dispatch.reload.state, dispatch.provider_id ]
    assert_match(/went after all: its id is 10863123/, @told.sole["content"])
    assert_equal 1, taken.size
  end

  # voip.ms may list a text with words other than those sent, so listed
  # nowhere is no proof it didn't go: it is never reported "not sent".
  test "listed nowhere an hour on, it is still unknown, never not sent: the agent is told not to send it again and to ask a person" do
    voipms_taking_then_hanging
    dispatch = lost_mid_send("On my way.")

    travel(Dispatch::CHECK_AFTER + 1.second) { check_and_tell }
    assert dispatch.reload.pending?, "not yet an hour: checked again"
    travel(Dispatch::NOT_LISTED_AFTER + 1.minute) { check_and_tell }
    assert dispatch.reload.unknown?, "never not_sent"
    told = @told.sole["content"]
    assert_match(/still unknown: an hour on, voip\.ms lists it nowhere, so it may or may not have gone\. Don't send it again; ask your person/, told)
    assert_no_match(/not sent|did not go|send it again if/i, told)

    travel(Dispatch::NOT_LISTED_AFTER + 3.hours) { check_and_tell }
    assert_equal 1, @told.size, "told once; checking stops"
  end

  test "voip.ms can't be asked for a day: whether it went stays unknown, and the agent is told not to send it again" do
    stub_request(:post, /voip\.ms/).to_raise(Net::OpenTimeout)
    dispatch = lost_mid_send("On my way.")

    travel(Dispatch::CHECK_AFTER + 1.second) { check_and_tell }
    travel(Dispatch::NOT_LISTED_AFTER + 1.minute) { check_and_tell }
    assert dispatch.reload.pending?, "a lookup that fails says nothing either way"
    assert_empty @told

    travel(Dispatch::CHECK_FOR + 1.hour) { check_and_tell }
    assert dispatch.reload.unknown?
    assert_match(/still unknown: voip\.ms could not be asked for a day.*Don't send it again; ask your person.*key #{dispatch.key}/, @told.sole["content"])
    travel(Dispatch::CHECK_FOR + 3.hours) { check_and_tell }
    assert_equal 1, @told.size, "told once; checking stops"
  end

  test "checks back off, to an hour apart" do
    stub_request(:post, /voip\.ms/).to_raise(Net::OpenTimeout)
    dispatch = lost_mid_send("On my way.")
    freeze_time
    [ 4, 8, 16, 32, 60, 60 ].each_with_index do |minutes, checks|
      dispatch.update_columns(checks: checks)
      assert_enqueued_with(job: DispatchCheckJob, args: [ dispatch ], at: minutes.minutes.from_now) { dispatch.check }
    end
  end

  test "one whose call is still running is left to the call" do
    voipms_taking_then_hanging
    invocation = @conversation.invocations.create!(task_id: "7", call_id: "c1", tool_name: "send_text",
      arguments: { "to" => "4165550199", "body" => "Hi" }, digest: "d", state: "running")
    dispatch = Dispatch.record(invocation, tool_name: "send_text", sender: "6475550123", fingerprint: "f")

    dispatch.check
    assert dispatch.reload.pending?
    assert_not_requested :post, /voip\.ms/
  end

  private
    # A send recorded, whose call was then lost (Invocation::LOST).
    def lost_mid_send(body)
      invocation = @conversation.invocations.create!(task_id: "7", call_id: "c1", tool_name: "send_text",
        arguments: { "to" => "4165550199", "body" => body }, digest: "d", state: "failed", error: Invocation::LOST)
      Dispatch.record(invocation, tool_name: "send_text", sender: "6475550123",
        fingerprint: Dispatch.fingerprint("send_text", "6475550123", "4165550199", body))
    end

    def check_and_tell
      perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current)
      perform_enqueued_jobs(only: DispatchReportJob)
    end
end
