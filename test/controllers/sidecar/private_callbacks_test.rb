require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The sidecar's callbacks into Rails: bearer-token transport with RAILS_TOKEN,
# never the sidecar's own token, no CSRF, and deny by default.
class Sidecar::PrivateCallbacksTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include ActionCable::TestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
  end
  teardown { remove_sidecar_settings }

  test "an access names exactly the user and agent asked about" do
    post "/agent/accesses", params: scope, headers: rails_bearer, as: :json

    assert_response :ok
    assert_equal({ "allowed" => true, "actorId" => @alice.id.to_s, "workspaceId" => @agent.id.to_s, "cwd" => @agent.workdir }, response.parsed_body)
  end

  test "another person's agent is refused" do
    mallory = create_user(name: "Mallory")

    post "/agent/accesses", params: { actorId: mallory.id.to_s, workspaceId: @agent.id.to_s }, headers: rails_bearer, as: :json
    assert_response :forbidden

    post "/agent/accesses", params: { actorId: @alice.id.to_s, workspaceId: "999999" }, headers: rails_bearer, as: :json
    assert_response :forbidden
  end

  test "only RAILS_TOKEN authenticates the transport" do
    [ {}, rails_bearer("wrong-token-0123456789"), rails_bearer(SIDECAR_TOKEN) ].each do |headers|
      post "/agent/accesses", params: scope, headers: headers, as: :json
      assert_response :unauthorized
    end
  end

  # With Cloudflare Access gone they would face the internet; the sidecar calls
  # the web container directly, never through kamal-proxy or Cloudflare.
  test "the callbacks answer only inside the host, even to the right token" do
    post "/agent/accesses", params: scope, headers: rails_bearer, as: :json
    assert_response :ok

    [ { "X-Forwarded-For" => "203.0.113.9" }, { "Cf-Connecting-Ip" => "203.0.113.9" }, { "Cf-Ray" => "8a1b2c3d4e5f-YYZ" },
      { "X-Forwarded-Host" => "assistants.example" } ].each do |outside|
      %w[ accesses invocations frames syncs sign_ins ].each do |callback|
        post "/agent/#{callback}", params: scope, headers: rails_bearer.merge(outside), as: :json
        assert_response :not_found, "#{callback} #{outside.keys.sole}"
      end
    end

    host! "localhost" # APP__URL's
    post "/agent/accesses", params: scope, headers: rails_bearer, as: :json
    assert_response :not_found
  end

  test "blank or shared tokens refuse every callback" do
    install_sidecar_settings(rails_token: nil)
    post "/agent/accesses", params: scope, headers: { "Authorization" => "Bearer " }, as: :json
    assert_response :unauthorized

    install_sidecar_settings(rails_token: SIDECAR_TOKEN)
    post "/agent/accesses", params: scope, headers: rails_bearer(SIDECAR_TOKEN), as: :json
    assert_response :unauthorized
  end

  test "a tool call runs once, skipping CSRF because the transport is authenticated instead" do
    payload = invocation_payload(@conversation, tool: "remember_note", arguments: { "key" => "dentist", "body" => "Tuesday 3pm" })

    with_forgery_protection do
      2.times { post "/agent/invocations", params: payload, headers: rails_bearer, as: :json }
    end

    assert_response :ok
    assert_equal({ "status" => "done", "result" => { "key" => "dentist", "body" => "Tuesday 3pm" }, "isError" => false }, response.parsed_body)
    assert_equal 1, @conversation.invocations.count
    assert_equal "Tuesday 3pm", @agent.notes.sole.body
  end

  test "a changed call under the same identity is a conflict and changes nothing" do
    post "/agent/invocations", params: invocation_payload(@conversation, tool: "remember_note", arguments: { "key" => "k", "body" => "first" }),
      headers: rails_bearer, as: :json
    post "/agent/invocations", params: invocation_payload(@conversation, tool: "remember_note", arguments: { "key" => "k", "body" => "second" }),
      headers: rails_bearer, as: :json

    assert_response :conflict
    assert_equal "first", @agent.notes.sole.body
  end

  test "a forged digest is a conflict" do
    payload = invocation_payload(@conversation, tool: "current_time", arguments: {}).merge(digest: "0" * 64)
    post "/agent/invocations", params: payload, headers: rails_bearer, as: :json

    assert_response :conflict
    assert_empty @conversation.invocations
  end

  test "a call naming another person's conversation reaches nothing" do
    mallory = create_user(name: "Mallory")
    theirs = create_conversation(mallory.agents.sole, durable_id: "99")
    payload = invocation_payload(theirs, tool: "current_time", arguments: {}).merge(actorId: @alice.id.to_s, workspaceId: @agent.id.to_s)

    post "/agent/invocations", params: payload, headers: rails_bearer, as: :json

    assert_response :not_found
    assert_empty theirs.invocations
  end

  test "a frame reaches the conversation it names, within the agent it names" do
    post "/agent/frames", params: scope.merge(conversationId: "12", seq: 3, busy: true, tail: "Hel", failure: nil), headers: rails_bearer, as: :json

    assert_response :no_content
    assert_equal "running", @conversation.reload.status

    post "/agent/frames", params: scope.merge(conversationId: "404", seq: 4, busy: true, tail: "x"), headers: rails_bearer, as: :json
    assert_response :not_found
  end

  test "a frame's tool output reaches the page, a malformed call is dropped, and the last frame's totals are kept" do
    tools = [ { callId: "call_b", name: "bash", status: "running", output: "x" * 9_000 }, { callId: "bad id!", name: "bash" }, "junk" ]
    post "/agent/frames", params: scope.merge(conversationId: "12", seq: 5, busy: true, tail: "", tools: tools), headers: rails_bearer, as: :json
    assert_response :no_content

    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    post "/agent/frames", params: scope.merge(conversationId: "12", seq: 6, busy: false, tail: "", tools: [], failure: nil,
      usage: { input: 3, output: 4, cacheRead: 0, cacheWrite: 0, totalTokens: 7, cost: { estimatedTotal: nil, basis: "price_unavailable" } }),
      headers: rails_bearer, as: :json
    assert_response :no_content
    assert_equal({ "input" => 3, "output" => 4, "cacheRead" => 0, "cacheWrite" => 0, "totalTokens" => 7, "cost" => nil }, @conversation.reload.usage)
  end

  test "a frame passes on only what started a summary, and nothing it does not know" do
    streams = capture_turbo_stream_broadcasts(@conversation) do
      post "/agent/frames", params: scope.merge(conversationId: "12", seq: 7, busy: true, tail: "",
        compaction: { trigger: "manual", error: "provider words" }, compactionFailed: { trigger: "sideways" }), headers: rails_bearer, as: :json
    end

    assert_response :no_content
    live = streams.find { it["target"] == "live_conversation_#{@conversation.id}" }.to_html
    assert_includes live, "Summarising earlier messages…"
    assert_not_includes live, "Couldn't summarise"
    assert_not_includes live, "provider words"
  end

  test "a frame's waiting messages replace the list under the reply, and a malformed one is dropped" do
    queued = [ { id: "31", mode: "steer", text: "Rome, not Paris", pictures: 0 }, { id: "x", mode: "steer", text: "bad" }, { id: "32", mode: "reject", text: "bad" } ]
    streams = capture_turbo_stream_broadcasts(@conversation) do
      post "/agent/frames", params: scope.merge(conversationId: "12", seq: 8, busy: true, tail: "", queued: queued), headers: rails_bearer, as: :json
    end

    list = streams.find { it["target"] == "queued_conversation_#{@conversation.id}" }
    assert_equal "morph", list["method"]
    assert_includes list.to_html, "Rome, not Paris"
    assert_includes list.to_html, "Steering"
    assert_not_includes list.to_html, "bad"

    # A frame that does not carry the list leaves it as it is.
    streams = capture_turbo_stream_broadcasts(@conversation) do
      post "/agent/frames", params: scope.merge(conversationId: "12", seq: 9, busy: true, tail: "x"), headers: rails_bearer, as: :json
    end
    assert_nil streams.find { it["target"] == "queued_conversation_#{@conversation.id}" }
  end

  test "a sync ping pulls that conversation before it answers; a failed pull is left to a job" do
    entries = stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "user", content: "Hello" } ], cursor: 1, more: false }.to_json)
    assert_no_enqueued_jobs do
      post "/agent/syncs", params: scope.merge(conversationId: "12"), headers: rails_bearer, as: :json
    end
    assert_response :no_content
    assert_requested entries
    assert_equal [ "Hello" ], @conversation.messages.pluck(:content)

    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(status: 503)
    assert_enqueued_with(job: ConversationSyncJob, args: [ @conversation ]) do
      post "/agent/syncs", params: scope.merge(conversationId: "12"), headers: rails_bearer, as: :json
    end
    assert_response :no_content
  end

  private
    def scope = { actorId: @alice.id.to_s, workspaceId: @agent.id.to_s }

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
end
