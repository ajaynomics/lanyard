require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The out-of-band inbox (#85): what others sent waits for the agent to finish,
# and the agent sees who wrote and how each starts, and takes some or all in
# sooner. The person's own waiting words are not its to take.
class Tool::WaitingMessagesTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  # A fixture transaction would itself hold the lock this regression measures.
  self.use_transactional_tests = false

  setup do
    install_sidecar_settings
    @person = create_user(name: "Maya-#{SecureRandom.hex(6)}")
    @agent = @person.agents.sole
    @conversation = create_conversation(@agent)
    mail = Conversation.received("Rome, not Paris?\nAnd a hotel near the station.", from: "acme/sam, task 9, on network acme", via: "Concourse mail",
      answer: "Answer with concourse_reply.")
    email = Conversation.received("Subject: Lunch\nDate: today\n\nAre you free?", from: "Robin <robin@example.com>", via: "Email", answer: "Reply by email.")
    @waiting = [ { id: "30", mode: "followUp", text: "And book dinner", pictures: 0 },
      { id: "31", mode: "followUp", text: mail, pictures: 0 }, { id: "32", mode: "followUp", text: email, pictures: 0 } ]
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12\?}).to_return { { body: { id: "12", status: "running", queued: @waiting }.to_json } }
    @changed = stub_request(:patch, %r{\A#{SIDECAR}/v1/conversations/12/queued/\d+\z}).to_return { |request|
      id = request.uri.path.split("/").last
      changed = @waiting.any? { it[:id] == id }
      @waiting.find { it[:id] == id }&.then { it[:mode] = JSON.parse(request.body)["whenBusy"] }
      { body: { changed: changed }.to_json } }
  end

  teardown do
    @person&.destroy!
    remove_sidecar_settings
  end

  # 23 Nov 2026: a 12-second sidecar answer held SQLite's one write lock,
  # and every other write in the install timed out behind it.
  test "it asks the sidecar outside the invocation's write transaction" do
    asked = 0
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12\?}).to_return do
      asked += 1
      assert_not Invocation.connection.transaction_open?, "the sidecar was asked inside the invocation's transaction"
      { body: { id: "12", status: "running", queued: @waiting }.to_json }
    end

    assert_equal [ "31", "32" ], use[:waiting].pluck(:id)
    assert_operator asked, :>, 0
  end

  test "it lists what others sent, who sent each and how it starts, never the person's own" do
    listed = use[:waiting]

    assert_equal [ "31", "32" ], listed.pluck(:id)
    assert_equal [ "Concourse", "acme/sam" ], listed.first.values_at(:channel, :from)
    assert_equal "Rome, not Paris?", listed.first[:starts]
    assert_equal [ "Email", "Robin <robin@example.com>", "Subject: Lunch" ], listed.second.values_at(:channel, :from, :starts)
    assert listed.all? { it[:untrusted] }
    assert_not_requested @changed
  end

  test "a queued phone transcript is not previewed before the read-only turn" do
    text = Conversation.received("Take a note.", from: Agent::VoiceCall::FROM, via: Agent::VoiceCall::VIA, answer: Agent::VoiceCall::SUMMARY)
    @waiting.unshift(id: "29", mode: "followUp", text: text, pictures: 0, phone: true)

    assert_equal [ "31", "32" ], use[:waiting].pluck(:id)
  end

  test "taken in, they are read after this step, in the order they came; the person's own stay as he left them" do
    result = use(take: [ "all" ])

    assert_equal [ "31", "32" ], result[:taken]
    assert_equal %w[ followUp steer steer ], @waiting.pluck(:mode)
    assert_match "after this step", result[:note]
  end

  test "one taken by its id; one no longer waiting, or the person's, is said so and left" do
    result = use(take: [ "32", "30", "99" ])

    assert_equal [ "32" ], result[:taken]
    assert_equal [ "30", "99" ], result[:not_waiting]
    assert_equal %w[ followUp followUp steer ], @waiting.pluck(:mode)
  end

  test "every agent can look it up, and it adds nothing to what it carries" do
    assert_includes @conversation.lookup_tools.map(&:tool_name), "waiting_messages"
    assert_not_includes @conversation.tools.map(&:tool_name), "waiting_messages"
  end

  private
    def use(arguments = {})
      payload = invocation_payload(@conversation, tool: "waiting_messages", arguments: arguments.stringify_keys)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: "toolu_1", tool: "waiting_messages",
        arguments: arguments.stringify_keys, digest: payload[:digest]).deep_symbolize_keys }
      receive.call
      perform_enqueued_jobs(only: InvocationCallJob)
      receive.call.fetch(:result)
    end
end
