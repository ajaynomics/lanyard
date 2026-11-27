require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# A connector's answer longer than the sidecar keeps of one result, counted
# in bytes (DurableAssistants::ResultBytes, Tool::Mcp::LongAnswer):
# on a Sprite, the whole of it is saved on the agent's computer as a file, the
# way a Gmail attachment is, and the model reads its start, where the rest
# is, and that it is there. The whole text waits in Active Storage, never in
# the ledger, and only for Invocation::FILE_WITHIN. Without a Sprite, the
# answer is cut as before, and says so.
class LongAnswersTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  LONG = Array.new(4_000) { |line| "Line #{line}: #{'words ' * 7}" }.join("\n").first(200_000).freeze

  setup do
    install_sidecar_settings
    @agent = create_user(name: "Alice").agents.sole
    @conversation = create_conversation(@agent)
    make_core(@agent, create_mcp_server(@agent, name: "records", tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ]))
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: LONG } ] } } })
  end
  teardown { remove_sidecar_settings }

  test "on a Sprite, a 200,000-character answer is saved whole, and the model reads its start and where the rest is" do
    @agent.create_computer!(provider: "sprites", state: "on")
    done = run_call

    assert_equal 200_000, LONG.length
    assert_equal true, done["file"]
    result = done["result"]
    assert LONG.start_with?(result["text"])
    assert_operator result["text"].length, :>, 40_000
    assert_equal([ { "name" => "search-answer.txt", "type" => "text/plain", "size" => LONG.bytesize, "held" => 0 } ], result["found_files"])
    assert_match "of its 200,000 characters", result["note"]
    assert_match "the whole answer is saved on your computer", result["note"]
    invocation = @conversation.invocations.sole
    assert_operator invocation.attributes.to_json.length, :<, DurableAssistants::ResultBytes::LIMIT, "the ledger keeps only the start"

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal LONG, response.body.force_encoding(Encoding::UTF_8)

    assert invocation.held_files.attached?
    travel(Invocation::FILE_WITHIN + 1.minute) { perform_enqueued_jobs(only: InvocationFilePurgeJob) }
    assert_not invocation.reload.held_files.attached?, "the whole text is kept no longer than the sidecar may fetch it"
  end

  test "an answer under 50,000 characters but over the sidecar's bytes, in a script of three bytes a character, is saved whole" do
    @agent.create_computer!(provider: "sprites", state: "on")
    wide = "これは長い答えの一行です。\n" * 2_000
    assert_operator wide.length, :<, 50_000
    assert_operator wide.bytesize, :>, 51_200
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: wide } ] } } })
    done = run_call

    assert_equal true, done["file"], "never cut silently by the sidecar"
    assert wide.start_with?(done.dig("result", "text"))
    assert_operator JSON.generate(done["result"]).bytesize, :<, 48_000

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_equal wide, response.body.force_encoding(Encoding::UTF_8)
  end

  test "without a Sprite, the answer is cut as before, and the model is told why" do
    done = run_call

    assert_nil done["file"]
    assert LONG.start_with?(done.dig("result", "text"))
    assert_operator JSON.generate(done["result"]).bytesize, :<, DurableAssistants::ResultBytes::ANSWER
    assert_match "has no computer of this app's to save the rest on", done.dig("result", "note")
    assert_not @conversation.invocations.sole.held_files.attached?
  end

  test "an answer within the limit is answered as it was" do
    @agent.create_computer!(provider: "sprites", state: "on")
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "short" } ] } } })
    done = run_call

    assert_nil done["file"]
    assert_equal({ "text" => "short" }, done["result"])
  end

  test "a connector image reaches the sidecar on replay even when its text is saved as a file" do
    @agent.create_computer!(provider: "sprites", state: "on")
    image = { "type" => "image", "mimeType" => "image/png", "data" => "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP2sAAAAASUVORK5CYII=" }
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: LONG }, image ] } } })
    log = StringIO.new
    Rails.logger.broadcast_to(listener = ActiveSupport::Logger.new(log))
    done = run_call
    invocation = @conversation.invocations.sole

    assert_equal [ image ], done["images"]
    assert_equal done, invoke, "replay returns the same image without running the tool again"
    assert_equal true, done["file"]
    assert LONG.start_with?(done.dig("result", "text"))
    assert_operator JSON.generate(done["result"]).bytesize, :<, DurableAssistants::ResultBytes::ANSWER
    assert_not_includes invocation.inspect, image["data"]
    assert_not_includes ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }), image["data"]
    assert_includes log.string, "Invocation Update"
    assert_not_includes log.string, image["data"]

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_equal LONG, response.body.force_encoding(Encoding::UTF_8)

    travel(Invocation::RESULTS_KEPT + 1.minute) do
      Invocation.prune_results
      assert_equal done["result"], invocation.reload.result
      assert_nil invocation.outcome[:images], "retaining the saved-file metadata does not retain the image"
    end
  ensure
    Rails.logger.stop_broadcasting_to(listener) if listener
  end

  private
    def run_call
      invoke
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke
    end

    def invoke
      @last = invocation_payload(@conversation, tool: "mcp__records__search", arguments: {}, call_id: "toolu_1")
      post "/agent/invocations", params: @last, headers: rails_bearer, as: :json
      response.parsed_body
    end

    def fetch = { actorId: @last[:actorId], workspaceId: @last[:workspaceId], conversationId: @last[:conversationId], taskId: @last[:taskId], callId: "toolu_1" }
end
