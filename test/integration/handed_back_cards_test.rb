require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# The 15 November case: an approval card waited 87 minutes, and the mail
# that steered meanwhile waited with it. Now a call waiting on an approval,
# with messages waiting for the agent, hands its card back to Rails
# (`handBack`). The agent reads its messages; Rails runs the call once if the
# person allows it, and tells the agent how it ended as a message.
class HandedBackCardsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @agent.notes.remember("old", "x")
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    @wakes = stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes").to_return(body: { rung: true }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "an approval handed back runs once when the person allows it, and the agent is told, once, as a steer" do
    assert_equal "waiting", invoke("forget_note", { "key" => "old" })["status"]
    card = @conversation.invocations.sole
    assert_not @conversation.held_by_card?, "an approval holds no steer: its call hands the card back"

    assert_equal({ "status" => "handedBack", "key" => card.wait_key, "card" => card.id }, invoke("forget_note", { "key" => "old" }, hand_back: true))
    assert card.reload.handed_back_at
    assert card.answerable?, "the card stays open for the person"
    assert_equal({ "status" => "handedBack", "key" => card.wait_key, "card" => card.id }, invoke("forget_note", { "key" => "old" }), "a replay after a crash too")

    perform_enqueued_jobs { card.approve!(by: @alice) }
    assert_equal 0, @agent.notes.count
    assert_not_requested @wakes # no wait in the sidecar to ring
    told = @submissions.sole
    assert_equal [ "invocation:#{card.id}", "steer" ], told.values_at("requestId", "whenBusy")
    assert_nil told["fromPerson"], "not the person's own: his steers stay ahead of it"
    assert_match(/\A\[Approval from the card you stopped waiting on\. .* It answers a call you made earlier/, told["content"])
    assert_match(/Alice allowed forget_note \{"key":"old"\}, and it ran once\. Its result:\n\n\{"forgotten":"old"\}\z/, words(told["content"]))

    assert_equal({ "status" => "done", "result" => { "forgotten" => "old" }, "isError" => false }, invoke("forget_note", { "key" => "old" }))
    perform_enqueued_jobs { InvocationReportJob.perform_later(card.reload) }
    assert_equal 1, @submissions.size, "the same request id is the same message"
    assert_equal 0, @agent.notes.count

    shown = @conversation.messages.create!(entry_key: "52", entry_id: 52, role: "user", content: told["content"])
    assert_equal "Approval", shown.incoming.channel
    assert_not shown.from_person?
  end

  test "a queued handed-back report is discarded if its conversation was deleted" do
    invoke("forget_note", { "key" => "old" })
    invoke("forget_note", { "key" => "old" }, hand_back: true)
    job = InvocationReportJob.new(@conversation.invocations.sole).serialize

    @conversation.destroy!
    assert_nothing_raised { ActiveJob::Base.execute(job) }
    assert_empty @submissions
  end

  test "a denial handed back is told to the agent, and nothing runs" do
    invoke("forget_note", { "key" => "old" })
    invoke("forget_note", { "key" => "old" }, hand_back: true)
    perform_enqueued_jobs { @conversation.invocations.sole.deny!(by: @alice) }

    assert_equal 1, @agent.notes.count
    assert_match(/Alice declined forget_note \{"key":"old"\}\. It did not run\.\z/, words(@submissions.sole["content"]))
  end

  test "a card handed back that nobody answers ends when it expires, and the agent is told" do
    invoke("forget_note", { "key" => "old" })
    invoke("forget_note", { "key" => "old" }, hand_back: true)
    card = @conversation.invocations.sole
    card.update!(expires_at: 1.minute.ago)
    perform_enqueued_jobs { Invocation.settle_handed_back }

    assert card.reload.failed?
    assert_equal 1, @agent.notes.count
    assert_match(/forget_note \{"key":"old"\} did not run to the end: Nobody answered in time\.\z/, words(@submissions.sole["content"]))
  end

  test "the person's decision before the hand-back is the call's result, as before" do
    invoke("forget_note", { "key" => "old" })
    @conversation.invocations.sole.approve!(by: @alice)

    assert_equal "done", invoke("forget_note", { "key" => "old" }, hand_back: true)["status"]
    assert_nil @conversation.invocations.sole.handed_back_at
    perform_enqueued_jobs
    assert_empty @submissions
  end

  test "a question, and a helper's approval, keep holding the step: Rails won't take them back" do
    assert_equal "waiting", invoke("ask_person", { "question" => "Tea?" }, call_id: "toolu_q")["status"]
    assert @conversation.held_by_card?
    assert_equal "waiting", invoke("ask_person", { "question" => "Tea?" }, call_id: "toolu_q", hand_back: true)["status"]
    assert_equal "waiting", invoke("forget_note", { "key" => "old" }, call_id: "toolu_h/toolu_a", hand_back: true)["status"]
    assert_equal "waiting", invoke("forget_note", { "key" => "old" }, call_id: "toolu_h/toolu_s/c1", hand_back: true)["status"]
    assert_equal [ nil, nil, nil ], @conversation.invocations.order(:id).pluck(:handed_back_at)
  end

  test "an approval on a script of the agent's own is handed back like the agent's own call, and the agent told as a steer" do
    assert_equal "waiting", invoke("forget_note", { "key" => "old" }, call_id: "toolu_s/c1")["status"]
    card = @conversation.invocations.sole
    assert_not @conversation.held_by_card?, "with a message waiting, the script's call hands the card back"

    assert_equal({ "status" => "handedBack", "key" => card.wait_key, "card" => card.id }, invoke("forget_note", { "key" => "old" }, call_id: "toolu_s/c1", hand_back: true))
    assert card.reload.handed_back_at
    perform_enqueued_jobs { card.approve!(by: @alice) }
    assert_equal 0, @agent.notes.count
    assert_match(/Alice allowed forget_note \{"key":"old"\}, and it ran once\./, words(@submissions.sole["content"]))
  end

  test "a handed-back connector result reaches the model as a steer with an image" do
    make_core(@agent, create_mcp_server(@agent, tools: [ mcp_tool("draw") ]))
    image = { "type" => "image", "mimeType" => "image/png", "data" => "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP2sAAAAASUVORK5CYII=" }
    stub_mcp_server(calls: { "draw" => ->(_) { { content: [ { type: "text", text: "Chart" }, image ] } } })
    assert_equal "waiting", invoke("mcp__wiki__draw", {})["status"]
    assert_equal "handedBack", invoke("mcp__wiki__draw", {}, hand_back: true)["status"]
    perform_enqueued_jobs { @conversation.invocations.sole.approve!(by: @alice) }

    told = @submissions.sole
    assert_equal "steer", told["whenBusy"]
    assert_match "Chart", told["content"].first.fetch("text")
    assert_equal [ image ], told["content"].select { it["type"] == "image" }
  end

  # The sidecar masks what a tool returns (agent/secret-mask.mjs); a result
  # handed back reaches the agent as a message instead, and is masked here.
  test "a handed-back result holding a key reaches the sidecar masked, and says so" do
    key = "sk-ant-api03-FakeExample0000MadeUp1111"
    @agent.notes.remember(key, "made up")
    invoke("forget_note", { "key" => key })
    invoke("forget_note", { "key" => key }, hand_back: true)
    perform_enqueued_jobs { @conversation.invocations.sole.approve!(by: @alice) }

    told = words(@submissions.sole["content"])
    assert_not_includes told, key
    assert_match(/Alice allowed forget_note \{"key":"sk-ant-\[masked\]"\}, and it ran once\. Its result:\n\n\{"forgotten":"sk-ant-\[masked\]"\}\n\n\[masked 2 secret-shaped values\]\z/, told)
  end

  test "what a person sends is theirs, and is never masked" do
    @conversation.receive("Use API_KEY=fakefakefake01 for the build.", from: "Sam <sam@example.com>", via: "Email", request_id: "email:1")
    assert_match(/Use API_KEY=fakefakefake01 for the build\.\z/, words(@submissions.sole["content"]))
  end

  private
    def invoke(tool, arguments, call_id: "toolu_1", hand_back: false)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      post "/agent/invocations", params: hand_back ? payload.merge(handBack: true) : payload, headers: rails_bearer, as: :json
      response.parsed_body
    end
end
