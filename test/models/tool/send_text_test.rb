require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/push_test_helper"
require_relative "../../test_helpers/voipms_test_helper"

class Tool::SendTextTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PushTestHelper
  include VoipmsTestHelper
  include ActiveJob::TestHelper

  setup do
    install_voipms_settings
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @agent.update!(phone_number: "+1 (647) 555-0123")
    @conversation = create_conversation(@agent)
    @forms = stub_voipms
  end

  teardown { remove_voipms_settings }

  test "an agent has it only with a number of its own, where the install has voip.ms, and knows its number" do
    assert_equal "6475550123", @agent.phone_number
    assert_includes tool_names, "send_text"
    assert_includes @agent.identity, "Your phone number is (647) 555-0123"

    with_setting(:voipms, :password, nil) { assert_not_includes tool_names, "send_text" }
    @agent.update!(phone_number: "")
    assert_nil @agent.phone_number
    assert_not_includes tool_names, "send_text"
    assert_not_includes @agent.identity, "phone"
  end

  test "a number is ten North American digits, and one agent's" do
    other = @maya.agents.create!(name: "Robin", instructions: "Help.", model: @agent.model)
    assert_not other.update(phone_number: "6475550123")
    assert_includes other.errors[:phone_number], "is another agent's"
    assert_not other.update(phone_number: "555-0123")
    assert_not other.update(phone_number: "+44 20 7946 0958")
    assert other.update(phone_number: "1-416-555-0199")
    assert_equal "4165550199", other.phone_number
  end

  test "each text waits for the person, then goes from the agent's own number" do
    assert_equal "waiting", receive({ "to" => "4165550199", "body" => "Your parcel is here." }, call_id: "c1")[:status]
    assert_empty @forms

    @conversation.invocations.find_by!(call_id: "c1").approve!(by: @maya)
    outcome = run_call("c1", "to" => "4165550199", "body" => "Your parcel is here.")
    assert_equal({ sent: "4165550199", from: "6475550123", id: 23434 }, outcome[:result])
    assert_equal [ "6475550123", "4165550199", "Your parcel is here." ], @forms.sole.values_at("did", "dst", "message")
  end

  test "the model can't choose the number it sends from" do
    outcome = receive({ "to" => "4165550199", "body" => "Hi", "did" => "9055550100" }, call_id: "c1")
    assert outcome[:isError]
    assert_match(/Invalid arguments/, outcome[:result][:error])
    assert_empty @forms
  end

  test "allowed always with one number, texts to it go at once and others still wait" do
    @agent.permissions.create!(tool_name: "send_text", recipient: "4165550199", granted_by: @maya)
    run_call("c1", "to" => "4165550199", "body" => "Hi")
    assert_equal 1, @forms.size
    assert_equal "waiting", receive({ "to" => "9055550100", "body" => "Hi" }, call_id: "c2")[:status]
  end

  test "past twenty a day it refuses, and the person hears once" do
    install_push_settings
    subscribe(@maya)
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    20.times { run_call("c#{it}", "to" => "4165550199", "body" => "Text #{it}") }
    assert_equal 20, @forms.size

    outcome = run_call("c20", "to" => "4165550199", "body" => "One more")
    assert outcome[:isError]
    assert_match(/You have sent 20 texts in the last 24 hours/, outcome[:result][:error])
    run_call("c21", "to" => "4165550199", "body" => "And another")
    assert_equal 20, @forms.size
    notices = enqueued_jobs.select { it["job_class"] == "Push::DeliveryJob" }
    assert_equal 1, notices.size, "one notice a day"
    assert_match(/reached 20 texts in a day/, notices.sole["arguments"].last["body"])

    travel 1.day + 1.minute do
      run_call("c22", "to" => "4165550199", "body" => "A new day")
      assert_equal 21, @forms.size
    end
  ensure
    remove_push_settings
  end

  test "voip.ms refusing fails the call with its reason, and nothing is sent again" do
    stub_voipms(status: "sms_apply_regulations")
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    outcome = run_call("c1", "to" => "4165550199", "body" => "Hi")
    assert_equal "voip.ms refused the text: sms_apply_regulations", outcome[:result][:error]
    travel(Invocation::RUN_LIMIT + 1.minute) { run_call("c1", "to" => "4165550199", "body" => "Hi") }
    assert_requested :post, /voip\.ms/, times: 1
  end

  private
    def tool_names = @agent.reload.conversation.definition[:tools].pluck(:name)

    def receive(arguments, call_id:)
      payload = invocation_payload(@conversation, tool: "send_text", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "send_text",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def run_call(call_id, arguments)
      receive(arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive(arguments, call_id: call_id)
    end
end
