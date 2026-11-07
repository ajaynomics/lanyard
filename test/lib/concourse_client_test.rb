require "test_helper"
require_relative "../test_helpers/concourse_test_helper"

class ConcourseClientTest < ActiveSupport::TestCase
  include ConcourseTestHelper

  setup do
    @client = DurableAssistants::Concourse::Client.new(organization: "avery", handle: "avery/durable-assistants", client_id: "client-1", client_secret: "secret-1")
  end

  test "a token comes from Ajent's client_credentials grant and is kept in the cache until a minute before it expires" do
    token = stub_concourse_token(expires_in: 3600)
    stub_concourse_identity
    with_memory_cache do |cache|
      @client.identity
      DurableAssistants::Concourse::Client.new(organization: "avery", handle: "avery/durable-assistants", client_id: "client-1", client_secret: "secret-1").identity

      assert_requested token, times: 1
      key = cache.instance_variable_get(:@data).keys.grep(/concourse\/token/).sole
      assert_not_includes key, "secret-1"
      travel 59.minutes + 1.second do
        assert_nil cache.read(key)
      end
    end
  end

  test "a 401 forgets the cached token" do
    stub_concourse_token
    stub_concourse(:get, "api/identity", { error: "invalid_token" }, status: 401)
    with_memory_cache do |cache|
      error = assert_raises(DurableAssistants::Concourse::Client::Error) { @client.identity }
      assert_equal 401, error.status
      assert_empty cache.instance_variable_get(:@data).keys.grep(/concourse\/token/)
    end
  end

  test "Ajent refusing the secret is said plainly" do
    stub_request(:post, TOKEN_URL).to_return(status: 401, body: { error: "invalid_client" }.to_json)

    error = assert_raises(DurableAssistants::Concourse::Client::Error) { @client.identity }
    assert_equal "Ajent refused the client id and secret.", error.message
  end

  test "identity must be the organization, handle and client entered" do
    stub_concourse_token
    stub_concourse_identity
    assert_equal 7, @client.identity["agent_id"]

    stub_concourse_identity(organization: "acme-agents")
    error = assert_raises(DurableAssistants::Concourse::Client::Error) { client_for("avery/durable-assistants").identity }
    assert_equal "These credentials belong to avery/durable-assistants in acme-agents on Concourse, not avery/durable-assistants in avery.", error.message

    stub_concourse_identity(release_line: 2)
    assert_raises(DurableAssistants::Concourse::Client::Error) { client_for("avery/durable-assistants").identity }
  end

  test "find reads the organization's directory" do
    stub_concourse_session
    stub_request(:get, "#{ORIGIN}/agents?query=travel").to_return(body: { agents: [ { handle: "avery/travel" } ] }.to_json)

    assert_equal [ { "handle" => "avery/travel" } ], @client.find("travel")
  end

  test "the inbox is the agent's paged tasks" do
    stub_concourse_session
    stub_request(:get, "#{ORIGIN}/agents/7/tasks?pageSize=50&pageToken=older")
      .to_return(body: { tasks: [ concourse_task ], blockedTasks: [], nextPageToken: "" }.to_json)

    assert_equal [ "task-1" ], @client.inbox("older")["tasks"].map { it["id"] }

    stub_request(:get, "#{ORIGIN}/agents/7/tasks?pageSize=50").to_return(body: { tasks: [] }.to_json)
    assert_raises(DurableAssistants::Concourse::Client::Error) { @client.inbox }
  end

  test "a send is A2A v1.0 SendMessage to the organization's gateway, returning at once" do
    stub_concourse_session
    send = stub_request(:post, "#{ORIGIN}/a2a/avery/avery/travel")
      .with(headers: { "A2A-Version" => "1.0", "Authorization" => "Bearer #{ACCESS_TOKEN}" }) { |request|
        body = JSON.parse(request.body)
        body["method"] == "SendMessage" && body.dig("params", "configuration", "returnImmediately") == true &&
          body.dig("params", "message") == { "messageId" => "msg-1", "role" => "ROLE_USER", "parts" => [ { "text" => "Hi" } ], "contextId" => "ctx-9" }
      }
      .to_return(body: { jsonrpc: "2.0", id: "msg-1", result: { task: concourse_task(id: "task-9") } }.to_json)

    assert_equal "task-9", @client.send_message("avery/travel", message_id: "msg-1", text: "Hi", context_id: "ctx-9")["id"]
    assert_requested send
  end

  test "a send that is refused is certain; one that got no answer may have landed" do
    stub_concourse_session
    stub_request(:post, "#{ORIGIN}/a2a/avery/avery/travel")
      .to_return(body: { jsonrpc: "2.0", id: "m", error: { code: -32001, message: "Task not found" } }.to_json)
    refused = assert_raises(DurableAssistants::Concourse::Client::Error) { @client.send_message("avery/travel", message_id: "m", text: "Hi") }
    assert_not refused.uncertain?

    stub_request(:post, "#{ORIGIN}/a2a/avery/avery/travel").to_timeout
    lost = assert_raises(DurableAssistants::Concourse::Client::Error) { @client.send_message("avery/travel", message_id: "m", text: "Hi") }
    assert lost.uncertain?

    assert_raises(DurableAssistants::Concourse::Client::Error) { @client.send_message("https://evil.example/x", message_id: "m", text: "Hi") }
  end

  test "a reply is the worker PATCH with an explicit state" do
    stub_concourse_session
    reply = stub_request(:patch, "#{ORIGIN}/tasks/task-1")
      .with(body: { state: "TASK_STATE_COMPLETED", message: { parts: [ { text: "Done" } ] } }.to_json)
      .to_return(body: concourse_task(state: "TASK_STATE_COMPLETED").to_json)

    assert_equal "TASK_STATE_COMPLETED", @client.reply("task-1", state: "TASK_STATE_COMPLETED", text: "Done").dig("status", "state")
    assert_requested reply
    assert_raises(DurableAssistants::Concourse::Client::Error) { @client.reply("task-1", state: "done") }
  end

  test "the doorbell yields ready, then each ping, and returns when the server closes it" do
    stub_concourse_session
    stream = "event: ready\ndata: {\"release_line\":3,\"connectionId\":\"#{SecureRandom.uuid}\",\"sessionId\":\"durable-assistants-1\"}\n\n" \
      ": keepalive\n\nevent: ping\ndata: {\"reason\":\"inbox\",\"taskId\":\"task-1\"}\n\nevent: ping\r\ndata: {}\r\n\r\n"
    doorbell = stub_request(:get, "#{ORIGIN}/api/doorbell")
      .with(headers: { "Accept" => "text/event-stream", "Concourse-Session-Id" => "durable-assistants-1", "Authorization" => "Bearer #{ACCESS_TOKEN}" })
      .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: stream)
    hints = []

    assert_nil @client.listen(session_id: "durable-assistants-1") { hints << it }

    assert_equal %i[ ready ping ping ], hints
    assert_requested doorbell
  end

  test "a ping before ready is ignored, a quiet stream ends, and a refused doorbell is an error" do
    stub_concourse_session
    stub_request(:get, "#{ORIGIN}/api/doorbell")
      .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: "event: ping\ndata: {}\n\n")
    hints = []
    @client.listen(session_id: "s") { hints << it }
    assert_empty hints

    stub_request(:get, "#{ORIGIN}/api/doorbell").to_raise(Net::ReadTimeout)
    assert_nil @client.listen(session_id: "s") { hints << it }

    stub_request(:get, "#{ORIGIN}/api/doorbell").to_return(status: 429, body: { error: "doorbell_capacity" }.to_json)
    assert_equal 429, assert_raises(DurableAssistants::Concourse::Client::Error) { @client.listen(session_id: "s") { } }.status
  end

  private
    def client_for(handle)
      DurableAssistants::Concourse::Client.new(organization: "avery", handle: handle, client_id: "client-1", client_secret: "secret-1")
    end

    def with_memory_cache
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield Rails.cache
    ensure
      Rails.cache = original
    end
end
