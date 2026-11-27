require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/voipms_test_helper"

class DispatchRetryTest < ActiveSupport::TestCase
  include AgentTestHelper
  include VoipmsTestHelper

  ARGUMENTS = { "to" => "4165550199", "body" => "Your parcel is ready." }.freeze

  setup do
    install_voipms_settings
    owner = create_user
    agent = owner.agents.sole
    agent.update!(phone_number: "6475550123")
    agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: owner)
    @conversation = create_conversation(agent)
  end

  teardown { remove_voipms_settings }

  test "a refusal of an overlapping attempt does not let a retry duplicate an unconfirmed send" do
    accepted = []
    attempts = 0
    writes = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "sendSMS" }.to_return do |request|
      attempts += 1
      if attempts == 2
        { body: { status: "sms_apply_regulations" }.to_json }
      else
        accepted << voipms_form(request)["message"]
        raise Net::ReadTimeout
      end
    end
    stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }
      .to_return(body: { status: "no_sms" }.to_json)

    first = nil
    # Both jobs got past the repeat check before the first recorded its send.
    # Pause the later job at that boundary; use the real ledger for both.
    before_recording("overlap", -> { first = run_call("first"); travel 1.second }) do
      assert run_call("overlap")[:isError]
    end

    dispatch = invocation("first").dispatch
    refusal = invocation("overlap").dispatch
    assert dispatch.checking?
    assert refusal.not_sent?
    assert_operator refusal.created_at, :>, dispatch.created_at
    assert_equal [ ARGUMENTS.fetch("body") ], accepted
    assert_equal [ ARGUMENTS.fetch("to"), dispatch.key ], first.fetch(:result).values_at(:unknown, :key)
    assert_nil first.dig(:result, :sent)

    travel(Dispatch::NOT_LISTED_AFTER + 1.minute) do
      DispatchCheckJob.perform_now(dispatch)
      assert dispatch.reload.unknown?
      assert_nil dispatch.provider_id
      assert_equal first, run_call("first"), "same call, same recorded result and key"
      assert_requested writes, times: 2, message: "the overlapping request was refused; replay made no write"

      retry_result = run_call("retry")
      assert_equal [ ARGUMENTS.fetch("body") ], accepted, "retry must not be accepted a second time"
      assert_requested writes, times: 2, message: "retry must not make another provider request"
      assert_match(/still unknown \(key #{dispatch.key}\)/, retry_result.dig(:result, :error))
      assert_nil invocation("retry").dispatch
    end
  end

  test "a definite refusal alone blocks replay, not a new send" do
    writes = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "sendSMS" }
      .to_return(body: { status: "sms_apply_regulations" }.to_json).then
      .to_return(body: { status: "success", sms: 23434 }.to_json)

    refused = run_call("refused")
    assert refused[:isError]
    assert invocation("refused").dispatch.not_sent?
    assert_equal refused, run_call("refused")
    assert_requested writes, times: 1

    assert_equal 23434, run_call("new").dig(:result, :id)
    assert_requested writes, times: 2
  end

  private
    def before_recording(call_id, pause)
      record = Dispatch.method(:record)
      Dispatch.define_singleton_method(:record) do |invocation, **attributes|
        pause.call if invocation.call_id == call_id
        record.call(invocation, **attributes)
      end
      yield
    ensure
      Dispatch.define_singleton_method(:record, record)
    end

    def invocation(call_id) = @conversation.invocations.find_by!(call_id: call_id)

    def receive(call_id)
      payload = invocation_payload(@conversation, tool: "send_text", arguments: ARGUMENTS, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "send_text",
        arguments: ARGUMENTS, digest: payload[:digest]).deep_symbolize_keys
    end

    def run_call(call_id)
      status = receive(call_id)
      return status unless status[:status] == "waiting"
      InvocationCallJob.perform_now(invocation(call_id))
      receive(call_id)
    end
end
