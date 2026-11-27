require "test_helper"
require_relative "../../../test_helpers/agent_test_helper"

class Agent::VoiceCall::RelayTest < ActiveSupport::TestCase
  include AgentTestHelper

  Sideband = Struct.new(:sent) do
    def write(event) = sent << event
    def async(&block) = Sync { block.call }
  end

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    @call = @agent.voice_calls.create!(delivery_id: "delivery", event_id: "evt", session_id: "live_fixture",
      body_digest: "digest", outcome: "accepted", reach: "owner")
    @url = "#{SIDECAR}/v1/conversations/12/phone-submissions"
    @sideband = Sideband.new([])
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "uses the read-only route once and speaks only that submission's answer" do
    @conversation.messages.create!(entry_key: "other", entry_id: 50, role: "assistant", content: "The next written reply.")
    submission = stub_request(:post, @url).with(body: hash_including("requestId" => "call:live_fixture:call_1", "whenBusy" => "reject"))
      .to_return(status: 202, body: { id: 7, status: "placed" }.to_json)
    reply = stub_request(:get, "#{@url}/7").with(query: hash_including({})).to_return(body: { status: "done", answer: "**Lunch** at noon." }.to_json)
    relay = Agent::VoiceCall::Relay.new(@call)
    2.times { relay.handle(question, @sideband) }

    assert_requested submission, times: 1
    assert_requested reply, times: 1
    assert_equal [ { type: "response.item.create", item: { type: "function_call_output", call_id: "call_1", output: "Lunch at noon." } },
      { type: "response.create" } ], @sideband.sent
  end

  test "a different caller's tool event reaches neither the thread nor the phone" do
    @call.update!(reach: "stranger")
    Agent::VoiceCall::Relay.new(@call).handle(question, @sideband)
    assert_not_requested :post, @url
    assert_empty @sideband.sent
  end

  test "a request still in flight times out without resubmitting it" do
    submission = stub_request(:post, @url).to_return(status: 202, body: { id: 7, status: "placed" }.to_json)
    stub_request(:get, "#{@url}/7").with(query: hash_including({})).to_return(body: { status: "placed" }.to_json)
    Agent::VoiceCall::Relay.new(@call, wait: 0.25).handle(question, @sideband)

    assert_requested submission, times: 1
    assert_equal Agent::VoiceCall::Relay::NO_ANSWER, @sideband.sent.first.dig(:item, :output)
  end

  private
    def question
      { "type" => "response.event", "event" => { "type" => "response.output_item.done", "item" =>
        { "type" => "function_call", "call_id" => "call_1", "name" => "ask_agent", "arguments" => { question: "When is lunch?" }.to_json } } }
    end
end
