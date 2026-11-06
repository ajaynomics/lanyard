require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The browser-facing resources: the application's identity and authorization
# adapters decide, CSRF stays on, and the sidecar is reached with its own token.
class Agent::BrowserResourcesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup { install_agent_adapters }
  teardown { remove_agent_adapters }

  test "without the application's identity adapter nothing is reachable" do
    Rails.application.config.x.pi_durable_identity = nil
    get "/workspaces/one/agent/conversations"

    assert_response :unauthorized
  end

  test "a workspace in the URL is not authority" do
    get "/workspaces/two/agent/conversations"

    assert_response :forbidden
  end

  test "admission is idempotent and carries the authorised scope with the sidecar token" do
    stub = stub_request(:post, "#{SIDECAR}/v1/conversations")
      .with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" },
            body: { requestId: "req-1", actorId: "alice", workspaceId: "one" })
      .to_return(status: 201, body: { id: 12 }.to_json)

    2.times { post "/workspaces/one/agent/conversations", params: { request_id: "req-1" }, as: :json }

    assert_requested stub, times: 2
    assert_equal 1, alice_in.conversations.count
    assert_equal "12", alice_in.conversations.sole.durable_id
  end

  test "a sidecar conversation already mapped to another request is a conflict, not a guess" do
    alice_in.conversations.create!(request_id: "earlier", durable_id: "12")
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: 12 }.to_json)

    post "/workspaces/one/agent/conversations", params: { request_id: "later" }, as: :json

    assert_response :conflict
    assert_equal 1, alice_in.conversations.count
  end

  test "another actor's conversation is not found" do
    theirs = Agent::Conversation.create!(actor_id: "bob", workspace_id: "one", request_id: "r", durable_id: "3")

    get "/workspaces/one/agent/conversations/#{theirs.id}/snapshot", as: :json
    assert_response :not_found
  end

  test "the snapshot shows the projection and never the raw Durable state" do
    conversation = alice_in.conversations.create!(request_id: "r", durable_id: "12")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12?actorId=alice&workspaceId=one")
      .to_return(status: 200, body: { id: 12, status: "done", entries: [ { id: "e1", role: "assistant", content: "hi", secret: "x" } ],
        pendingInputs: [], failure: { reason: "interrupted", detail: "raw provider text" }, usage: { totalTokens: 3 },
        state: { docs: {} }, inspection: { tasks: [] } }.to_json)

    get "/workspaces/one/agent/conversations/#{conversation.id}/snapshot", as: :json

    assert_response :ok
    assert_equal %w[entries failure id pendingInputs status usage], response.parsed_body.keys.sort
    assert_equal({ "reason" => "interrupted" }, response.parsed_body["failure"])
    assert_equal [ { "id" => "e1", "role" => "assistant", "content" => "hi" } ], response.parsed_body["entries"]
  end

  test "a run that stopped without an answer shows only its reason" do
    conversation = alice_in.conversations.create!(request_id: "r", durable_id: "12")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12?actorId=alice&workspaceId=one")
      .to_return(status: 200, body: { id: 12, status: "error", entries: [], pendingInputs: [],
        failure: { reason: "interrupted", detail: "raw provider text" }, usage: nil }.to_json)

    get "/workspaces/one/agent/conversations/#{conversation.id}/snapshot", headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :ok
    assert_includes response.body, "Stopped: interrupted"
    assert_not_includes response.body, "raw provider text"
  end

  test "an answer form becomes the ordered native answer" do
    conversation = alice_in.conversations.create!(request_id: "r", durable_id: "12")
    stub = stub_request(:post, "#{SIDECAR}/v1/conversations/12/answers/question%3A4%3Atool%3A1")
      .with(body: { answer: { selections: [ %w[two one], [] ], text: "custom" }, actorId: "alice", workspaceId: "one" })
      .to_return(status: 200, body: { ok: true }.to_json)

    post "/workspaces/one/agent/conversations/#{conversation.id}/inputs/question:4:tool:1/answer",
      params: { answer: { selections: { "1" => [ "" ], "0" => [ "", "two", "one" ] }, text: "custom" } }

    assert_requested stub
    assert_redirected_to "/workspaces/one/agent/conversations/#{conversation.id}"
  end

  # Rails 8.2 verifies the browser's Sec-Fetch-Site header; a cross-site post
  # from an untrusted origin is refused before the sidecar is called.
  test "browser resources keep CSRF protection" do
    conversation = alice_in.conversations.create!(request_id: "r", durable_id: "12")
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post "/workspaces/one/agent/conversations/#{conversation.id}/submissions", params: { request_id: "s1", content: "hello" },
      headers: { "Sec-Fetch-Site" => "cross-site", "Origin" => "https://attacker.invalid" }

    assert_response :unprocessable_content
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "an unreachable or refusing sidecar is reported, not retried" do
    conversation = alice_in.conversations.create!(request_id: "r", durable_id: "12")
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 503, body: "{}")

    post "/workspaces/one/agent/conversations/#{conversation.id}/submissions", params: { request_id: "s1", content: "hello" }, as: :json

    assert_response :service_unavailable
  end

  test "conversation content, answers and tool arguments are filtered from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("content" => "private prompt", "answer" => { "text" => "x" }, "arguments" => { "body" => "y" }, "request_id" => "r")

    assert_equal "[FILTERED]", filtered["content"]
    assert_equal "[FILTERED]", filtered["answer"]
    assert_equal "[FILTERED]", filtered["arguments"]
    assert_equal "r", filtered["request_id"]
  end
end
