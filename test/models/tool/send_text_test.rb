require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/push_test_helper"
require_relative "../../test_helpers/voipms_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

class Tool::SendTextTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PushTestHelper
  include VoipmsTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  PILOT_PASSWORD = [ "synthetic", "pilot", "api", "password" ].join("-").freeze

  setup do
    install_voipms_settings
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @agent.update!(phone_number: "+1 (647) 555-0123")
    @conversation = create_conversation(@agent)
    @forms = stub_voipms
  end

  teardown do
    remove_voipms_settings
    remove_fake_passbolt
  end

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
    other = @maya.personal_workspace.agents.create!(user: @maya, name: "Robin", instructions: "Help.", model: @agent.model)
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
    assert_equal "texts", notices.sole["arguments"].last["kind"]

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

  # A live case: voip.ms answered after the app gave up, and the texts went.
  test "a send voip.ms answers too late is looked up: found, it was sent, with its id" do
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "sendSMS" }.to_raise(Net::ReadTimeout)
    stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }.to_return(body: { status: "success",
      sms: [ { id: "23999", date: Time.current.utc.strftime("%Y-%m-%d %H:%M:%S"), type: "0", did: "6475550123", contact: "4165550199", message: "Hi" } ] }.to_json)

    outcome = run_call("c1", "to" => "4165550199", "body" => "Hi")
    assert_equal({ sent: "4165550199", from: "6475550123", id: 23999 }, outcome[:result])
  end

  test "a send voip.ms answers too late and doesn't list is unknown, not failed, and a replay of the call never sends it again" do
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    sends = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "sendSMS" }.to_raise(Net::ReadTimeout)
    stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }.to_return(body: { status: "no_sms" }.to_json)

    outcome = run_call("c1", "to" => "4165550199", "body" => "Hi")
    assert_not outcome[:isError], outcome.inspect
    assert_equal "4165550199", outcome[:result][:unknown]
    assert_match(/may have gone.*Don't send it again/, outcome[:result][:note])
    assert_equal "succeeded", @conversation.invocations.find_by!(call_id: "c1").state, "counted against the day's texts, as one that went"

    assert_equal outcome, receive({ "to" => "4165550199", "body" => "Hi" }, call_id: "c1"), "a replay reads what was recorded"
    travel(Invocation::RUN_LIMIT + 1.minute) { run_call("c1", "to" => "4165550199", "body" => "Hi") }
    assert_requested sends, times: 1
  end

  # Lost only once its job began it (#238): a job still queued has sent nothing.
  test "a call lost while sending fails as lost when replayed, and is never sent again" do
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    assert_equal "waiting", receive({ "to" => "4165550199", "body" => "Hi" }, call_id: "c1")[:status], "claimed, its job not yet run"
    assert_equal "waiting", receive({ "to" => "4165550199", "body" => "Hi" }, call_id: "c1")[:status], "a replay meanwhile waits"
    @conversation.invocations.find_by!(call_id: "c1").update_columns(started_at: Time.current) # its job began, and its worker was killed
    travel(Invocation::RUN_LIMIT + 1.minute) do
      assert_equal "send_text: #{Invocation::LOST}", receive({ "to" => "4165550199", "body" => "Hi" }, call_id: "c1").dig(:result, :error)
    end
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_empty @forms, "the job finds it no longer running"
  end

  # The live case (#86): voip.ms took a 172-character text, sent it as an MMS
  # and never answered in time; the call was recorded failed, and nothing but
  # a hand check of voip.ms's log showed it went.
  test "voip.ms takes a long text and hangs past the wait: the call says sent, with its id, and the agent's retry sends nothing" do
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    taken = voipms_taking_then_hanging
    body = "Your table for four is booked for 7:30 tonight. Ask for the window seat when you arrive, and call the front desk " \
      "if the train is late; they hold a table 15 minutes. See you"
    assert_equal 172, body.length

    outcome = run_call("c1", "to" => "4165550199", "body" => body)
    assert_equal({ sent: "4165550199", from: "6475550123", id: 10863123 }, outcome[:result], "sent, not failed")

    retry_outcome = run_call("c2", "to" => "4165550199", "body" => body)
    assert retry_outcome[:isError]
    assert_match(/This same text went to 4165550199 at .* \(voip\.ms id 10863123\), so it wasn't sent again/, retry_outcome[:result][:error])
    assert_equal 1, taken.size, "sent once"

    travel(Dispatch::REPEAT_WITHIN + 1.minute) { run_call("c3", "to" => "4165550199", "body" => body) }
    assert_equal 2, taken.size, "the same words later are a new text"
  end

  test "the send is recorded, with its own key, before voip.ms is asked" do
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    recorded = nil
    stub_request(:post, /voip\.ms/).to_return do
      recorded = @conversation.invocations.find_by!(call_id: "c1").dispatch&.attributes&.slice("state", "sender", "tool_name", "key")
      { body: { status: "success", sms: 23434 }.to_json }
    end

    run_call("c1", "to" => "4165550199", "body" => "Hi")
    assert_equal %w[ pending 6475550123 send_text ], recorded&.values_at("state", "sender", "tool_name")
    assert_match(/\A\w{24}\z/, recorded["key"])
    dispatch = @conversation.invocations.find_by!(call_id: "c1").dispatch
    assert_equal [ "sent", "23434" ], [ dispatch.state, dispatch.provider_id ]
  end

  test "one voip.ms doesn't list yet is unknown with its key, a retry meanwhile sends nothing, and once listed the agent is told it went" do
    install_sidecar_settings
    told = stub_sidecar_submissions
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    taken = voipms_taking_then_hanging(listed_after: 3.minutes)

    outcome = run_call("c1", "to" => "4165550199", "body" => "On my way.")
    dispatch = @conversation.invocations.find_by!(call_id: "c1").dispatch
    assert_equal({ unknown: "4165550199", from: "6475550123", key: dispatch.key, note: Tool::SendText::UNCONFIRMED }, outcome[:result])
    assert dispatch.checking?

    retry_outcome = run_call("c2", "to" => "4165550199", "body" => "On my way.")
    assert_match(/may have gone and is still being checked \(key #{dispatch.key}\), so it wasn't sent again/, retry_outcome[:result][:error])

    travel(Dispatch::CHECK_AFTER + 1.second) { perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current) }
    assert dispatch.reload.checking?, "not listed yet: checked again later"
    assert_empty told

    travel(10.minutes) do
      perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current)
      perform_enqueued_jobs(only: DispatchReportJob)
    end
    assert_equal [ "sent", "10863123" ], [ dispatch.reload.state, dispatch.provider_id ]
    assert_match(/send_text .*On my way.*went after all: its id is 10863123\. Don't send it again/, told.sole["content"])
    assert_equal "dispatch:#{dispatch.id}", told.sole["requestId"]
    assert_equal 1, taken.size, "sent once"
  ensure
    remove_sidecar_settings
  end

  test "a call whose send was recorded is never sent again, even if its job runs twice" do
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    taken = voipms_taking_then_hanging(listed_after: 1.day)
    first = run_call("c1", "to" => "4165550199", "body" => "Hi")
    invocation = @conversation.invocations.find_by!(call_id: "c1")

    invocation.update_columns(state: "running", result: nil)
    invocation.call_outside
    assert_equal 1, taken.size
    assert_equal first[:result], invocation.reload.result.deep_symbolize_keys, "the same key, still being checked"
  end

  # The live case's other half: had voip.ms listed the MMS with other words,
  # the hour's checks would have found nothing, and "not sent" would have
  # invited the agent to send it a second time.
  test "voip.ms never lists it: an hour on it is still unknown, the agent is told to ask a person, and its retry sends nothing" do
    install_sidecar_settings
    told = stub_sidecar_submissions
    @agent.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    taken = voipms_taking_then_hanging(listed_after: 1.week)
    run_call("c1", "to" => "4165550199", "body" => "On my way.")
    dispatch = @conversation.invocations.find_by!(call_id: "c1").dispatch

    travel(Dispatch::NOT_LISTED_AFTER + 1.minute) do
      perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current)
      perform_enqueued_jobs(only: DispatchReportJob)
    end
    assert dispatch.reload.unknown?, "still unknown, never not sent"
    assert_match(/still unknown: .*Don't send it again; ask your person/, told.sole["content"])

    travel(Dispatch::NOT_LISTED_AFTER + 2.hours) do
      retry_outcome = run_call("c2", "to" => "4165550199", "body" => "On my way.")
      assert_match(/may have gone and whether it did is still unknown \(key #{dispatch.key}\), so it wasn't sent again\. Ask your person/,
        retry_outcome[:result][:error])
    end
    assert_equal 1, taken.size, "sent once"
  ensure
    remove_sidecar_settings
  end

  # The real case (#227): one workspace's agent texts from a number on that
  # workspace's own voip.ms account, while the install's account is another
  # person's. The credential is read from the vault entry its owner named.
  test "an agent in a workspace with its own voip.ms account texts with it; one in a workspace with none, with the install's" do
    miles = pilot_agent
    [ @agent, miles ].each { it.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya) }

    run_call("c1", "to" => "4165550199", "body" => "From the install's.")
    run_call("c2", { "to" => "4165550199", "body" => "From Pilot's." }, create_conversation(miles))

    assert_equal [ [ "6475550123", "texts@example.com", "synthetic-api-password" ], [ "4165550100", "maya", PILOT_PASSWORD ] ],
      @forms.map { it.values_at("did", "api_username", "api_password") }
    assert_not_includes passbolt_calls, PILOT_PASSWORD, "never in the vault command's arguments"

    with_setting(:voipms, :password, nil) do
      assert_includes miles.reload.conversation.definition[:tools].pluck(:name), "send_text", "its own account needs none of the install's"
      assert_not_includes tool_names, "send_text"
    end
  end

  test "a send to voip.ms that times out is looked up, then and later, with the same account as the send" do
    miles = pilot_agent
    miles.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
    conversation = create_conversation(miles)
    taken = voipms_taking_then_hanging(listed_after: 3.minutes)

    run_call("c1", { "to" => "4165550199", "body" => "On my way." }, conversation)
    dispatch = conversation.invocations.find_by!(call_id: "c1").dispatch
    assert dispatch.checking?
    travel(10.minutes) { perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current) }

    assert_equal [ "sent", "10863123" ], [ dispatch.reload.state, dispatch.provider_id ]
    assert_equal 1, taken.size
    asked = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { voipms_form(it) }
    assert_equal [ [ "sendSMS", "maya", PILOT_PASSWORD ], [ "getSMS", "maya", PILOT_PASSWORD ] ],
      asked.map { it.values_at("method", "api_username", "api_password") }.uniq
  end

  test "a workspace's account its vault can't find is not sent, and the install's is not used instead" do
    miles = pilot_agent(entry: "Pilot voip.ms (gone)")
    miles.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)

    outcome = run_call("c1", { "to" => "4165550199", "body" => "Hi" }, create_conversation(miles))
    assert outcome[:isError]
    assert_match(/Nothing called Pilot voip\.ms \(gone\) is shared with the agents/, outcome[:result][:error])
    assert_empty @forms
  end

  test "a workspace's account saved with no address is not sent, and the install's is not used instead" do
    assert_refused_entry(uri: nil, saved_for: "no address")
  end

  test "a workspace's account saved for another site is not sent, and the install's is not used instead" do
    assert_refused_entry(uri: "https://voip.example.com", saved_for: "voip.example.com")
  end

  test "its account's sign-in is the app's to use, never the agent's to fill or list" do
    miles = pilot_agent
    assert miles.reserved_sign_in?("pilot VOIP.MS")
    assert_not @agent.reserved_sign_in?("Pilot voip.ms")
  end

  private
    def tool_names = @agent.reload.conversation.definition[:tools].pluck(:name)

    # An agent with a number in Pilot, a shared workspace whose own voip.ms
    # account the vault holds under `entry`.
    def pilot_agent(entry: "Pilot voip.ms", uri: "https://voip.ms")
      install_fake_passbolt(name: "Pilot voip.ms", uri: uri, password: PILOT_PASSWORD)
      pilot = Workspace.make(name: "Pilot", owner: @maya)
      pilot.update!(voipms_vault_entry: entry)
      pilot.agents.create!(user: @maya, name: "Miles", instructions: "Help.", model: @agent.model, phone_number: "4165550100")
    end

    def assert_refused_entry(uri:, saved_for:)
      miles = pilot_agent(uri: uri)
      miles.permissions.create!(tool_name: "send_text", recipient: "", granted_by: @maya)
      outcome = run_call("c1", { "to" => "4165550199", "body" => "Hi" }, create_conversation(miles))
      assert outcome[:isError]
      assert_equal "Pilot voip.ms is saved for #{saved_for}, not voip.ms, so it is not sent there.", outcome[:result][:error]
      assert_empty @forms
    end

    def receive(arguments, call_id:, conversation: @conversation)
      payload = invocation_payload(conversation, tool: "send_text", arguments: arguments, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: "send_text",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    # The messages the sidecar was asked to deliver to the thread.
    def stub_sidecar_submissions
      told = []
      stub_request(:post, %r{/v1/conversations/12/submissions}).to_return do |request|
        told << JSON.parse(request.body)
        { status: 202, body: { id: told.size, status: "queued" }.to_json }
      end
      told
    end

    def run_call(call_id, arguments, conversation = @conversation)
      receive(arguments, call_id: call_id, conversation: conversation)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive(arguments, call_id: call_id, conversation: conversation)
    end
end
