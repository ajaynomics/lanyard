require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Tool::PlaceCallTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  TRIGGER = "http://10.0.0.9:8080/call".freeze
  TOKEN = "synthetic-trigger-token-0123".freeze
  NUMBER = "15555550123".freeze

  setup do
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @conversation = create_conversation(@agent)
    @agent.workspace.update!(approval_policy: "everything")
    @voice = Rails.application.config.x.voice
    @previous_voice = @voice.dup
    @token_file = Tempfile.new("trigger-token").tap { it.write("#{TOKEN}\n"); it.close }
    @voice.merge!(enabled: true, agent_id: @agent.id.to_s, call_trigger_url: TRIGGER, call_trigger_token_file: @token_file.path)
  end

  teardown do
    @voice.replace(@previous_voice)
    @token_file.unlink
  end

  test "only the install's voice agent has it, and only with the trigger and its token set" do
    assert_includes tool_names(@agent), "place_call"

    other = @agent.workspace.agents.create!(user: @maya, name: "Robin", instructions: "Help.", model: @agent.model)
    assert_not_includes tool_names(other), "place_call"
    %i[ call_trigger_url call_trigger_token_file ].each do |key|
      with_setting(:voice, key, nil) { assert_not_includes tool_names(@agent), "place_call", "without #{key}" }
    end
    with_setting(:voice, :enabled, false) { assert_not_includes tool_names(@agent), "place_call" }
  end

  test "any number in international form is sent once, as digits in a JSON body, with no card" do
    { "+442071838750" => "442071838750", "15555550123" => "15555550123", "4155550123" => "4155550123", "+8613800138000" => "8613800138000" }.each do |number, digits|
      trigger = stub_request(:post, TRIGGER)
        .with(body: { number: digits }.to_json, headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{TOKEN}" }).to_return(status: 202)

      result = placed_call(number, call_id: number)[:result]
      assert_equal [ "carrier_answered", digits ], result.values_at(:call, :number), number
      assert_not_sent_again(trigger, number, number)
      WebMock.reset!
    end
  end

  test "anything but a number in international form is refused before any request" do
    trigger = stub_request(:post, TRIGGER)
    [ "0442071838750", "+0442071838750", "1555abc0123", "555012", "1234567890123456", "1555 555 0123", "15555550123;1",
      "1555-555-0123", "++15555550123", "15555550123\n", "" ].each_with_index do |number, index|
      outcome = receive({ "number" => number }, call_id: "bad#{index}")
      assert outcome[:isError], number.inspect
      assert_not Tool::PlaceCall::NUMBER.match?(number), number.inspect
      perform_enqueued_jobs(only: InvocationCallJob)
    end
    assert_not_requested trigger
  end

  test "it reaches someone else: under the normal policy it asks first; where everything is approved, it goes straight to the job" do
    trigger = stub_request(:post, TRIGGER).to_return(status: 202)
    @agent.workspace.update!(approval_policy: "others")
    receive({ "number" => NUMBER }, call_id: "p-others")
    assert @conversation.invocations.find_by!(call_id: "p-others").awaiting_person?
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_not_requested trigger

    @agent.workspace.update!(approval_policy: "everything")
    assert_equal "carrier_answered", placed_call(NUMBER, call_id: "p-everything")[:result][:call]
    @agent.workspace.update!(approval_policy: nil)
    with_setting(:app, :approve_everything, true) do
      assert_equal "carrier_answered", placed_call(NUMBER, call_id: "p-install")[:result][:call]
    end
    assert_requested trigger, times: 2
  end

  test "the web side never reads the bearer: with no token file the call still goes to the job, which refuses, sending nothing" do
    trigger = stub_request(:post, TRIGGER)
    refused = "The call trigger's token file is missing, empty or unreadable, so no call was made."
    { "missing" => -> { File.delete(@token_file.path) if File.exist?(@token_file.path) }, "empty" => -> { File.write(@token_file.path, "\n") } }.each do |state, make|
      make.call
      outcome = placed_call(NUMBER, call_id: "c-#{state}")
      assert_equal refused, outcome[:result][:error], state
    end
    assert_not_requested trigger

    File.write(@token_file.path, "rotated-#{TOKEN}\n")
    approved = stub_request(:post, TRIGGER).with(headers: { "Authorization" => "Bearer rotated-#{TOKEN}" }).to_return(status: 202)
    assert_equal "carrier_answered", placed_call[:result][:call]
    assert_requested approved, times: 1
  end

  test "a token file emptied before the job runs refuses at call time, and sends nothing" do
    trigger = stub_request(:post, TRIGGER)
    assert_equal "waiting", receive({ "number" => NUMBER }, call_id: "c1")[:status]
    File.write(@token_file.path, "")
    outcome = run_call("c1")
    assert_equal "The call trigger's token file is missing, empty or unreadable, so no call was made.", outcome[:result][:error]
    assert_not_includes outcome.to_json, TOKEN
    assert_not_requested trigger
  end

  test "a call is claimed for the job role's calls queue, not run inline" do
    trigger = stub_request(:post, TRIGGER).to_return(status: 202)
    assert_enqueued_jobs(1, only: InvocationCallJob, queue: "calls") do
      assert_equal "waiting", receive({ "number" => NUMBER }, call_id: "c1")[:status]
    end
    assert @conversation.invocations.find_by!(call_id: "c1").running?
    assert_not_requested trigger
  end

  test "it posts once to the trigger with its bearer; a 202 is the carrier's answer, and is not sent again" do
    trigger = stub_request(:post, TRIGGER).with(headers: { "Authorization" => "Bearer #{TOKEN}" }).to_return(status: 202)

    result = placed_call[:result]
    assert_equal [ "carrier_answered", NUMBER ], result.values_at(:call, :number)
    assert_equal "The carrier answered the call. That alone doesn't show the person heard you, or that sound went both ways. Not tried again.",
      result[:note]
    assert_not_sent_again(trigger)
  end

  test "a 409 is uncertain, since the phone may have rung, and is not sent again" do
    trigger = stub_request(:post, TRIGGER).to_return(status: 409)

    result = placed_call[:result]
    assert_equal "uncertain", result[:call]
    assert_equal "The gateway didn't connect the call: the line was busy, calls were closed, or it rang and nobody answered. " \
      "The phone may have rung, so whether the call reached anyone is unknown. Not tried again.", result[:note]
    assert_not_sent_again(trigger)
  end

  test "the trigger's own refusals before dialling fail, naming no body" do
    trigger = stub_request(:post, TRIGGER).to_return({ status: 401, body: "body-#{TOKEN}" }, { status: 400 }, { status: 404 }, { status: 405 }, { status: 413 })

    assert_equal({ call: "failed", number: NUMBER, note: "The gateway refused this install's token, so nothing was dialled. Not tried again." },
      placed_call(call_id: "c1")[:result])
    %w[ c2 c3 c4 c5 ].each do |call_id|
      result = placed_call(call_id: call_id)[:result]
      assert_equal "failed", result[:call], call_id
      assert_match(/\AThe gateway turned the request away \(HTTP \d+\) before dialling, so nothing was dialled\. Not tried again\.\z/, result[:note])
    end
    assert_requested trigger, times: 5
  end

  test "a 503 failed before the dial was asked for, so nothing was dialled" do
    trigger = stub_request(:post, TRIGGER).to_return(status: 503)

    assert_equal({ call: "failed", number: NUMBER, note: "The gateway couldn't reach its phone system before dialling, so nothing was dialled. Not tried again." },
      placed_call[:result])
    assert_not_sent_again(trigger)
  end

  test "a 504 after the dial was asked for is uncertain, with one POST and never another" do
    trigger = stub_request(:post, TRIGGER).to_return(status: 504)

    result = placed_call[:result]
    assert_equal "uncertain", result[:call]
    assert_equal "The gateway lost its phone system after asking it to dial. " \
      "The phone may have rung, so whether the call reached anyone is unknown. Not tried again.", result[:note]
    assert_not_sent_again(trigger)
  end

  test "a status the trigger doesn't document is uncertain and never sent again" do
    [ 500, 502, 418 ].each_with_index do |status, index|
      trigger = stub_request(:post, TRIGGER).to_return(status: status)

      result = placed_call(call_id: "u#{index}")[:result]
      assert_equal "uncertain", result[:call], status.to_s
      assert_match(/\AThe gateway answered HTTP #{status} after the request was sent\. The phone may have rung/, result[:note])
      assert_not_sent_again(trigger, "u#{index}")
      WebMock.reset!
    end
  end

  test "a call timed out or cut off after it was sent is uncertain, and neither the ledger nor its job sends it again" do
    [ Net::ReadTimeout, Errno::ECONNRESET, EOFError ].each_with_index do |problem, index|
      trigger = stub_request(:post, TRIGGER).to_raise(problem)

      result = placed_call(call_id: "c#{index}")[:result]
      assert_equal "uncertain", result[:call], problem.name
      assert_match(/\AThe request was sent, then cut off or timed out \(\w+\)\. The phone may have rung/, result[:note])
      assert_not_sent_again(trigger, "c#{index}")
      WebMock.reset!
    end
  end

  test "a job lost after beginning the call never begins it again, and past RUN_LIMIT the call may or may not have happened" do
    trigger = stub_request(:post, TRIGGER).to_return(status: 202)
    receive({ "number" => NUMBER }, call_id: "c1")
    @conversation.invocations.find_by!(call_id: "c1").update!(started_at: Time.current)

    perform_enqueued_jobs(only: InvocationCallJob)
    travel Invocation::RUN_LIMIT + 1.minute
    outcome = receive({ "number" => NUMBER }, call_id: "c1")
    assert_equal "place_call: #{Invocation::LOST}", outcome[:result][:error]
    assert_not_requested trigger
  end

  private
    def tool_names(agent) = agent.reload.own_tools.map(&:tool_name)

    # The job run again, and the sidecar asking again, send nothing more.
    def assert_not_sent_again(trigger, call_id = "c1", number = NUMBER)
      InvocationCallJob.perform_now(@conversation.invocations.find_by!(call_id: call_id))
      receive({ "number" => number }, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_requested trigger, times: 1
    end

    def placed_call(number = NUMBER, call_id: "c1")
      receive({ "number" => number }, call_id: call_id)
      run_call(call_id, number)
    end

    def run_call(call_id, number = NUMBER)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive({ "number" => number }, call_id: call_id)
    end

    def receive(arguments, call_id:)
      payload = invocation_payload(@conversation, tool: "place_call", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "place_call",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
